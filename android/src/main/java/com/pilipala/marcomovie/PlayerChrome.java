package com.pilipala.marcomovie;

import android.graphics.*;
import android.graphics.drawable.GradientDrawable;
import android.view.*;
import android.widget.*;

/** Three independent floating regions with one visibility/focus owner. */
final class PlayerChrome {
    final MainActivity a;
    final boolean modernTv;
    final boolean isLiveStream;
    final FrameLayout overlay;
    final View topShade, bottomShade;
    final LinearLayout dock, progress, heading;
    final LinearLayout actionHost, badgeRow;
    final LinearLayout loadingPill;
    final LinearLayout centerRow;
    final LinearLayout topActions;
    final LinearLayout tvTopRightHud;
    final TextView hudProgressView;
    final View hudDivider;
    final Button backBtn;
    final FrameLayout lockBtn;
    final LinearLayout unlockPill;
    final TextView rewindBtn, forwardBtn;
    final TextView loadingText,
            episodeLabel,
            titleView,
            seekHint,
            wallClock,
            persistentClock,
            cardTitleView;
    final Button fsBtn;
    final StateGlyph state;
    final TextView resolution;
    final Cms.Video chromeVideo;
    boolean loading = true;
    boolean progressOnlyMode = false;
    final Rect windowInsets = new Rect();
    boolean layoutPending;
    String lastBadgeSignature = "";
    String lastWallClock = "";
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
                new android.text.style.ForegroundColorSpan(0xf2f5f8fd),
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
                        paint.setColor(0x74c8d1e0);
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
                new android.text.style.ForegroundColorSpan(0xb2cad2e0),
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
            pill.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
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
            pill.setBackground(modernSurface(0x1cffffff, 4.2f, 0x1effffff));
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
                            new int[] {modernTv ? 0x8c000000 : 0xc4000000, 0x00000000}));
        } else {
            topShade.setBackgroundColor(Color.TRANSPARENT);
        }
        float u = modernUnit(a);
        overlay.addView(
                topShade,
                new FrameLayout.LayoutParams(-1, modernTv ? vp(a, 110) : a.dp(160), Gravity.TOP));
        bottomShade = new View(a);
        if (a.isTvDevice()) {
            bottomShade.setBackground(
                    new GradientDrawable(
                            GradientDrawable.Orientation.BOTTOM_TOP,
                            new int[] {modernTv ? 0x84000000 : 0xb8000000, 0x00000000}));
        } else {
            bottomShade.setBackgroundColor(Color.TRANSPARENT);
        }
        overlay.addView(
                bottomShade,
                new FrameLayout.LayoutParams(
                        -1, modernTv ? vp(a, 176) : a.dp(210), Gravity.BOTTOM));
        heading = a.vertical();
        heading.setTag("player-heading");
        if (!a.isTvDevice()) {
            topActions = a.row();
            topActions.setPadding(0, 0, 0, a.dp(8));
            backBtn = a.navButton("‹ 返回", "player-back", a::leavePlayback);
            backBtn.setTextColor(MainActivity.WHITE);
            backBtn.setBackground(chromeSurface(0xcc22222a, 17, 0x33ffffff));
            topActions.addView(backBtn, new LinearLayout.LayoutParams(-2, a.dp(34)));
            View spacer = new View(a);
            topActions.addView(spacer, new LinearLayout.LayoutParams(0, 1, 1));
            // Orientation toggle lives only on the progress row ("全屏横屏 / 退出全屏").
            heading.addView(topActions, new LinearLayout.LayoutParams(-1, -2));
        } else {
            topActions = null;
            backBtn = null;
        }
        LinearLayout titleRow = a.row();
        titleRow.setGravity(Gravity.CENTER_VERTICAL);
        titleView = a.text(video.title, a.isPortrait() ? 20 : 26, MainActivity.WHITE);
        if (modernTv) {
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
        titleLp.rightMargin = modernTv ? vp(a, 14) : a.dp(10);
        titleRow.addView(titleView, titleLp);
        resolution = a.text("分辨率读取中", 11, 0xffeeeef2);
        resolution.setTag("player-resolution");
        resolution.setSingleLine();
        resolution.setEllipsize(android.text.TextUtils.TruncateAt.END);
        resolution.setPadding(a.dp(9), a.dp(3), a.dp(9), a.dp(3));
        resolution.setBackground(chromeSurface(0xb824242c, 10, 0x28ffffff));
        if (modernTv) resolution.setVisibility(View.GONE);
        titleRow.addView(resolution, new LinearLayout.LayoutParams(-2, -2));
        if (modernTv) {
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
            LinearLayout clockRow = a.row();
            a.playClock = a.text("--:-- / --:--", 12, MainActivity.WHITE);
            a.playClock.setGravity(Gravity.LEFT | Gravity.CENTER_VERTICAL);
            a.playClock.setPadding(a.dp(8), 0, a.dp(12), 0);
            clockRow.addView(a.playClock, new LinearLayout.LayoutParams(0, -2, 1));
            seekHint = a.text("", 12, 0xffe5e7eb);
            seekHint.setTag("player-seek-hint");
            seekHint.setGravity(Gravity.RIGHT | Gravity.CENTER_VERTICAL);
            seekHint.setPadding(a.dp(8), 0, a.dp(8), 0);
            seekHint.setVisibility(View.GONE);
            clockRow.addView(seekHint, new LinearLayout.LayoutParams(-2, -2));
            if (!a.isTvDevice()) {
                fsBtn =
                        a.navButton(
                                a.isPortrait() ? "⛶ 全屏横屏" : "⛶ 退出全屏",
                                "player-fullscreen",
                                a::togglePlayerOrientation);
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
                                Math.min(a.dp(760), Math.max(a.dp(220), width - a.dp(48))),
                                -2,
                                Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
                track.bottomMargin = a.dp(94);
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
            if (a.isTvDevice()) {
                dock.setPadding(a.dp(6), a.dp(5), a.dp(6), a.dp(5));
            } else {
                dock.setPadding(a.dp(3), a.dp(5), a.dp(3), a.dp(5));
            }
            dock.setClipChildren(true);
            dock.setClipToPadding(true);
            dock.setClipToOutline(true);
            dock.setBackground(chromeSurface(0xd81c1c22, a.isTvDevice() ? 26 : 24, 0x2affffff));
            UiCompat.setElevation(dock, a.dp(10));
            FrameLayout.LayoutParams dockLp;
            if (a.isTvDevice()) {
                dockLp =
                        new FrameLayout.LayoutParams(
                                Math.min(a.dp(612), Math.max(a.dp(240), width - a.dp(32))),
                                -2,
                                Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
                dockLp.bottomMargin = a.dp(16);
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
                    a.togglePlayback();
                    a.showControls(true);
                });
        if (!a.isTvDevice()) {
            centerRow = a.row();
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
            lockBtn.setOnClickListener(v -> PlaybackController.setPlayerLocked(a, true));
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
            unlockPill.setOnClickListener(v -> PlaybackController.setPlayerLocked(a, false));
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
        loadingPill.setPadding(a.dp(24), a.dp(16), a.dp(24), a.dp(16));
        loadingPill.setBackground(chromeSurface(0xe01c1c22, 24, 0x2affffff));
        UiCompat.setElevation(loadingPill, a.dp(10));
        loadingPill.addView(
                new PlaybackLoading.Ring(a), new LinearLayout.LayoutParams(a.dp(26), a.dp(26)));
        String epTitle =
                episode != null && episode.name != null && !episode.name.isEmpty()
                        ? " " + episode.name
                        : "";
        loadingText = a.text("正在加载" + epTitle + "…", 14, MainActivity.WHITE);
        loadingText.setPadding(a.dp(14), 0, 0, 0);
        loadingPill.addView(loadingText);
        a.playbackLayer.addView(loadingPill, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));

        String initialPersistentTime = formatWallTime();
        if (a.isTvDevice()) {
            tvTopRightHud = a.row();
            tvTopRightHud.setTag("player-tv-top-right-hud");
            tvTopRightHud.setGravity(Gravity.CENTER_VERTICAL);
            tvTopRightHud.setFocusable(false);
            tvTopRightHud.setClickable(false);
            tvTopRightHud.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
            int hudBgColor =
                    a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false) ? 0xdc161820 : 0x8f12151d;
            tvTopRightHud.setBackground(modernSurface(hudBgColor, 999f, 0x24ffffff));
            tvTopRightHud.setPadding(vp(a, 12.5f), vp(a, 5.5f), vp(a, 12.5f), vp(a, 5.5f));

            hudProgressView = a.text("", 12.5f, 0xf2f5f8fd);
            hudProgressView.setTag("player-hud-progress");
            hudProgressView.setFocusable(false);
            hudProgressView.setClickable(false);
            hudProgressView.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 12.5f);
            hudProgressView.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            hudProgressView.setFontFeatureSettings("tnum");
            if (android.os.Build.VERSION.SDK_INT >= 21) {
                hudProgressView.setLetterSpacing(0.022f);
            }
            hudProgressView.setIncludeFontPadding(false);
            hudProgressView.setSingleLine();
            hudProgressView.setShadowLayer(u * 1.6f, 0, u * 0.6f, 0x55000000);
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
            divBg.setColor(0x2effffff);
            divBg.setCornerRadius(u * 1f);
            hudDivider.setBackground(divBg);
            LinearLayout.LayoutParams divLp =
                    new LinearLayout.LayoutParams(Math.max(1, Math.round(u * 1f)), vp(a, 10.5f));
            divLp.leftMargin = vp(a, 9);
            divLp.rightMargin = vp(a, 9);
            tvTopRightHud.addView(hudDivider, divLp);

            persistentClock = a.text("", 12.5f, 0xf4f6f9fe);
            persistentClock.setTag("player-persistent-clock");
            persistentClock.setFocusable(false);
            persistentClock.setClickable(false);
            persistentClock.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 12.5f);
            persistentClock.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            persistentClock.setFontFeatureSettings("tnum");
            if (android.os.Build.VERSION.SDK_INT >= 21) {
                persistentClock.setLetterSpacing(0.045f);
            }
            persistentClock.setIncludeFontPadding(false);
            persistentClock.setSingleLine();
            persistentClock.setShadowLayer(u * 1.6f, 0, u * 0.6f, 0x55000000);
            persistentClock.setText(styledWallTime(initialPersistentTime));
            tvTopRightHud.addView(persistentClock, new LinearLayout.LayoutParams(-2, -2));

            // Starts hidden because controlsVisible == true on entry; reveals automatically in
            // full-screen playback once the toolbar hides.
            tvTopRightHud.setVisibility(View.GONE);
            FrameLayout.LayoutParams hudLp =
                    new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.END);
            hudLp.topMargin = vp(a, 20);
            hudLp.rightMargin = vp(a, 28);
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

    TextView buildSeekCircle(String label, int deltaMs) {
        TextView btn = a.text(label, 12, MainActivity.WHITE);
        btn.setGravity(Gravity.CENTER);
        btn.setTypeface(null, Typeface.BOLD);
        GradientDrawable bg = a.bg(0x99303034, 29);
        bg.setStroke(a.dp(1), 0x33ffffff);
        btn.setBackground(bg);
        btn.setOnClickListener(
                v -> {
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
                                    : (modernTv && a.prepared && a.playing && !loading
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
            dock.setPadding(a.dp(6), a.dp(5), a.dp(6), a.dp(5));
            int edge = Math.min(a.dp(16), width / 8);
            int maxDock = a.dp(612);
            int dockWidth = Math.max(0, Math.min(maxDock, width - edge * 2));
            int dockBottom = a.dp(16);
            place(
                    dock,
                    dockWidth,
                    -2,
                    Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL,
                    0,
                    0,
                    0,
                    dockBottom);
            int left = Math.min(a.dp(24), width / 8);
            int right = left;
            int trackWidth = Math.max(0, Math.min(a.dp(760), width - left - right));
            left += Math.max(0, (width - left - right - trackWidth) / 2);
            int progressHeight = Math.max(progress.getMeasuredHeight(), a.dp(62));
            int bottom = Math.max(a.dp(94), dock.getMeasuredHeight() + a.dp(28));
            bottom = Math.max(0, Math.min(bottom, height - progressHeight));
            place(progress, trackWidth, -2, Gravity.BOTTOM | Gravity.LEFT, left, 0, right, bottom);
            int side = Math.min(a.dp(44), width / 8);
            place(heading, -1, -2, Gravity.TOP, side, Math.min(a.dp(24), height / 8), side, 0);
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

    void resolution(int width, int height) {
        if (a.player != null && a.prepared) {
            resolution.setText(a.player.videoResolution());
        } else {
            resolution.setText(width > 0 && height > 0 ? width + " × " + height : "分辨率未知");
        }
    }

    void setLoading(boolean value) {
        loading = value;
        update();
    }

    void switchEpisode(Cms.Episode episode, Cms.Line line) {
        String lineName = line == null || line.name == null ? "" : line.name;
        String epName = episode == null || episode.name == null ? "" : episode.name;
        episodeLabel.setText(epName + (lineName.isEmpty() ? "" : "  ·  " + lineName));
        if (cardTitleView != null) {
            cardTitleView.setText(formatCardTitle(chromeVideo, episode));
        }
        resolution.setText("分辨率读取中");
        String statusMsg = "正在加载" + (epName.isEmpty() ? "" : " " + epName) + "…";
        if (a.playStatus != null) a.playStatus.setText(statusMsg);
        loadingText.setText(statusMsg);
        loading = true;
        update();
    }

    void setProgressOnlyMode(boolean progressOnly) {
        if (this.progressOnlyMode == progressOnly) return;
        this.progressOnlyMode = progressOnly;
        int otherVis = progressOnly ? View.INVISIBLE : View.VISIBLE;
        topShade.setVisibility(otherVis);
        heading.setVisibility(otherVis);
        if (modernTv) {
            dock.setVisibility(View.VISIBLE);
            if (actionHost != null) actionHost.setVisibility(otherVis);
        } else {
            dock.setVisibility(otherVis);
            if (lockBtn != null) lockBtn.setVisibility(otherVis);
        }
        seekHint.setVisibility(progressOnly ? View.VISIBLE : View.GONE);
        update();
        if (a.playbackControls != null) {
            a.playbackControls.visible(a.controlsVisible);
        }
    }

    void updatePlaybackHud(int displayPosMs, int durationMs, boolean live) {
        if (tvTopRightHud == null || hudProgressView == null) return;
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

    void syncClockViews() {
        String now = formatWallTime();
        boolean timeChanged = !now.equals(lastWallClock);
        if (timeChanged) {
            lastWallClock = now;
        }
        if (a.isTvDevice()) {
            boolean hudEnabled = a.prefs.getBoolean(Prefs.TV_PLAYER_TOP_RIGHT_HUD, true);
            boolean showHud = hudEnabled && !a.miniMode && !a.controlsVisible;
            if (persistentClock != null
                    && (timeChanged || persistentClock.getText().length() == 0)) {
                persistentClock.setText(styledWallTime(now));
            }
            if (tvTopRightHud != null) {
                int targetVis = showHud ? View.VISIBLE : View.GONE;
                if (tvTopRightHud.getVisibility() != targetVis) {
                    tvTopRightHud.setVisibility(targetVis);
                }
            }
            if (wallClock != null) {
                if (timeChanged) {
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
        boolean showSpinner = loading && !a.prepared && a.playbackLoading == null && !a.miniMode;
        if (loadingPill.getVisibility() != (showSpinner ? View.VISIBLE : View.GONE)) {
            loadingPill.setVisibility(showSpinner ? View.VISIBLE : View.GONE);
        }
        if (!a.controlsVisible && !loading && a.prepared) {
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
            if (modernTv) {
                a.playStatus.setVisibility(
                        loading || !a.prepared || !a.playing ? View.VISIBLE : View.GONE);
            } else if (!a.isTvDevice()) {
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
                                : (modernTv && a.prepared && a.playing ? View.GONE : View.VISIBLE));
        state.setVisibility(stateVis);
        if (centerRow != null) centerRow.setVisibility(stateVis);
        state.setContentDescription(!a.prepared ? "正在准备" : a.playing ? "正在播放，确认暂停" : "已暂停，确认继续");
        state.invalidate();
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
