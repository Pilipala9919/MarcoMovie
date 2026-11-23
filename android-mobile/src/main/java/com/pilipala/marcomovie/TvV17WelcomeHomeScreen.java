package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * Apple tvOS-inspired minimalist first-open / empty-source Home landing page. Strictly honors
 * {@link HomeDock#topSafeInsetPx()} and adaptive side margins so content never overlaps the
 * top navigation bar on any TV screen size or DPI scale.
 */
final class TvV17WelcomeHomeScreen {
    private static final int GLYPH_QR = 0;
    private static final int GLYPH_CINEMA = 1;
    private static final int GLYPH_SYNC = 2;

    private final MainActivity a;

    TvV17WelcomeHomeScreen(MainActivity activity) {
        a = activity;
    }

    void show() {
        a.renderPage("", "", true);
        if (a.current != null) a.current.home = true;

        int leftPad = a.homeDock != null ? a.homeDock.leftSafeInsetPx() : a.dp(44);
        int rightPad = a.homeDock != null ? a.homeDock.rightSafeInsetPx() : a.dp(44);
        int topPad = a.homeDock != null ? a.homeDock.topSafeInsetPx() : a.dp(88);
        int bottomPad = a.dp(24);
        a.body.setPadding(leftPad, topPad, rightPad, bottomPad);
        a.body.setClipChildren(false);
        a.body.setClipToPadding(false);

        int siteCount = a.config != null && a.config.sites != null ? a.config.sites.size() : 0;
        int supportedCount = 0;
        if (a.config != null && a.config.sites != null) {
            for (Cms.Site s : a.config.sites) {
                if (a.available(s)) supportedCount++;
            }
        }

        // Main 2-column cinematic split stage
        LinearLayout stage = a.row();
        stage.setTag("v17-welcome-stage");
        stage.setGravity(Gravity.CENTER_VERTICAL);
        stage.setClipChildren(false);
        stage.setClipToPadding(false);

        // Left: Main Frosted Editorial Hero Card
        LinearLayout heroCard = a.vertical();
        heroCard.setTag("v17-welcome-hero");
        heroCard.setClipChildren(false);
        heroCard.setClipToPadding(false);
        heroCard.setPadding(a.dp(32), a.dp(30), a.dp(32), a.dp(28));
        heroCard.setBackground(
                glassSurface(a.privateMode ? 0x6b221b14 : 0x66141a28, 24, 0x2cffffff));
        UiCompat.setElevation(heroCard, a.dp(12));

        // Status badge pill
        String badgeText;
        int badgeColor;
        int badgeBg;
        if (a.privateMode) {
            badgeText = "● 隐私空间 · 独立数据隔离";
            badgeColor = 0xfffbbf24;
            badgeBg = 0x24fbbf24;
        } else if (siteCount > 0) {
            badgeText = "● 已保存 " + siteCount + " 个片源（可用 " + supportedCount + "）";
            badgeColor = 0xff66d4cf;
            badgeBg = 0x2466d4cf;
        } else {
            badgeText = "● MARCO MOVIE · 私人客厅影院";
            badgeColor = 0xff8ab8ff;
            badgeBg = 0x2460a5fa;
        }
        TextView badge = a.text(badgeText, 12f, badgeColor);
        badge.setTypeface(null, Typeface.BOLD);
        badge.setPadding(a.dp(12), a.dp(5), a.dp(12), a.dp(5));
        badge.setBackground(TvV17Surface.rounded(badgeBg, a.dp(999), 0x26ffffff, a.dp(1)));
        heroCard.addView(badge, new LinearLayout.LayoutParams(-2, -2));
        a.gap(heroCard, 18);

        // Headline
        TextView title = a.text("把今晚，留给好故事。", 32f, TvV17Theme.TEXT);
        title.setTypeface(null, Typeface.BOLD);
        title.setLineSpacing(a.dp(4), 1f);
        heroCard.addView(title);
        a.gap(heroCard, 12);

        // Lead copy
        String lead =
                siteCount > 0
                        ? "已导入影视配置，选择一个可用片源即可进入大屏片库；也可以随时扫码追加新源或直接观看电视直播。"
                        : "专为客厅大屏打造的原生影音播放器。手机扫码导入影视或直播源，畅享 4K 杜比视界、全景声与丝滑遥控体验。";
        TextView subtitle = a.text(lead, 14f, 0xb8ebebf5);
        subtitle.setLineSpacing(a.dp(5), 1f);
        heroCard.addView(subtitle);
        a.gap(heroCard, 26);

        // Primary CTA Row
        LinearLayout primaryRow = a.row();
        primaryRow.setGravity(Gravity.CENTER_VERTICAL);
        primaryRow.setClipChildren(false);
        primaryRow.setClipToPadding(false);

        final View firstPrimary;
        if (a.config == null) {
            firstPrimary = buildActionPill("＋ 导入我的配置", "primary", true, () -> a.importDialog());
            addPill(primaryRow, firstPrimary, false);
        } else {
            firstPrimary = buildActionPill("选择片源开始浏览", "primary", true, a::chooseSources);
            addPill(primaryRow, firstPrimary, false);
            addPill(
                    primaryRow,
                    buildActionPill("＋ 添加新源", "welcome-add-source", false, a::importDialog),
                    true);
        }
        addPill(
                primaryRow,
                buildActionPill(
                        "电视直播",
                        "welcome-live",
                        false,
                        () -> a.open(new MainActivity.Screen(a::liveSources), true)),
                true);
        heroCard.addView(primaryRow, new LinearLayout.LayoutParams(-1, -2));
        a.gap(heroCard, 12);

        // Secondary utility pills row
        LinearLayout utilityRow = a.row();
        utilityRow.setGravity(Gravity.CENTER_VERTICAL);
        utilityRow.setClipChildren(false);
        utilityRow.setClipToPadding(false);
        if (!a.privateMode) {
            addPill(
                    utilityRow,
                    buildActionPill(
                            "多端同步",
                            "cloud-sync-open",
                            false,
                            () -> CloudSyncDialog.show(a, a::refresh)),
                    false);
        }
        addPill(
                utilityRow,
                buildActionPill(
                        "观看历史",
                        "history-open",
                        false,
                        () -> a.open(new MainActivity.Screen(a::historyPage), true)),
                !a.privateMode);
        addPill(
                utilityRow,
                buildActionPill(
                        "系统设置",
                        "welcome-settings",
                        false,
                        () -> a.open(new MainActivity.Screen(a::settings), true)),
                true);
        heroCard.addView(utilityRow, new LinearLayout.LayoutParams(-1, -2));

        LinearLayout.LayoutParams heroLp = new LinearLayout.LayoutParams(0, -2, 1.24f);
        heroLp.rightMargin = a.dp(22);
        stage.addView(heroCard, heroLp);

        // Right: 3 Minimalist Feature Highlight Cards
        LinearLayout rightCol = a.vertical();
        rightCol.setClipChildren(false);
        rightCol.setClipToPadding(false);
        addFeatureCard(
                rightCol,
                GLYPH_QR,
                0xff60a5fa,
                "扫码即导 · 免遥控打字",
                "手机扫码即可输入订阅网址，或直接上传本地 TXT / JSON / M3U 直播文件。",
                false);
        addFeatureCard(
                rightCol,
                GLYPH_CINEMA,
                0xff34d399,
                "影院级原生解码体验",
                "自动记忆片头片尾与剧集字幕，支持杜比视界与长按上下键快捷切集。",
                true);
        addFeatureCard(
                rightCol,
                GLYPH_SYNC,
                0xfffbbf24,
                "多端协同与局域网互联",
                "内置无线投屏接收、云端配置同步与蜘蛛网关，与手机/iOS 端无缝配合。",
                true);
        stage.addView(rightCol, new LinearLayout.LayoutParams(0, -2, 0.92f));

        a.body.addView(stage, new LinearLayout.LayoutParams(-1, -2));
        a.gap(a.body, 18);

        // Subtle Footer Disclaimer
        LinearLayout footer = a.row();
        footer.setGravity(Gravity.CENTER_VERTICAL);
        footer.setPadding(a.dp(18), a.dp(11), a.dp(18), a.dp(11));
        footer.setBackground(glassSurface(0x3a121622, 14, 0x1affffff));
        TextView note = a.text(MainActivity.FIRST_RUN_DECLARATION, 12f, 0x8cebebf5);
        note.setLineSpacing(a.dp(3), 1f);
        footer.addView(note, new LinearLayout.LayoutParams(0, -2, 1f));
        a.body.addView(footer, new LinearLayout.LayoutParams(-1, -2));

        a.ui.post(
                () -> {
                    if (firstPrimary.isAttachedToWindow()) {
                        firstPrimary.requestFocus();
                    }
                });
    }

    private void addPill(LinearLayout row, View pill, boolean withGap) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, a.dp(42));
        if (withGap) lp.leftMargin = a.dp(10);
        row.addView(pill, lp);
    }

    private LinearLayout buildActionPill(
            String label, String tag, final boolean primary, final Runnable onClick) {
        LinearLayout pill = a.row();
        pill.setTag(tag);
        pill.setGravity(Gravity.CENTER);
        pill.setFocusable(true);
        pill.setFocusableInTouchMode(true);
        pill.setClickable(true);
        UiCompat.setDefaultFocusHighlightEnabled(pill, false);
        pill.setPadding(a.dp(primary ? 22 : 16), 0, a.dp(primary ? 22 : 16), 0);

        final TextView tv = a.text(label, primary ? 14.5f : 13.5f, TvV17Theme.TEXT);
        tv.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
        tv.setSingleLine(true);
        tv.setIncludeFontPadding(false);
        pill.addView(tv, new LinearLayout.LayoutParams(-2, -2));

        styleActionPill(pill, tv, primary, false);
        a.pressFeedback(pill);
        pill.setOnClickListener(v -> onClick.run());
        pill.setOnFocusChangeListener(
                (v, focused) -> {
                    FocusMotion.unclipAncestors(pill);
                    styleActionPill(pill, tv, primary, focused);
                    UiCompat.setElevation(pill, focused ? a.dp(10) : (primary ? a.dp(4) : 0));
                    pill.animate()
                            .scaleX(focused ? 1.05f : 1f)
                            .scaleY(focused ? 1.05f : 1f)
                            .setDuration(a.reduced ? 0 : 120)
                            .start();
                });
        pill.setOnKeyListener(
                (v, keyCode, event) -> {
                    if (event.getAction() == KeyEvent.ACTION_DOWN
                            && keyCode == KeyEvent.KEYCODE_DPAD_UP
                            && a.homeDock != null
                            && a.homeDock.tvTopLabeled
                            && a.homeDock.items.length > 0
                            && (primary
                                    || "welcome-live".equals(tag)
                                    || "welcome-add-source".equals(tag))) {
                        a.homeDock.items[0].requestFocus();
                        return true;
                    }
                    return false;
                });
        return pill;
    }

    private void styleActionPill(LinearLayout pill, TextView tv, boolean primary, boolean focused) {
        if (focused) {
            pill.setBackground(TvV17Surface.rounded(0xf8ffffff, a.dp(999), 0xffffffff, a.dp(1)));
            tv.setTextColor(0xff0b0e14);
        } else if (primary) {
            pill.setBackground(TvV17Surface.rounded(0xdc0a84ff, a.dp(999), 0x667cb8ff, a.dp(1)));
            tv.setTextColor(Color.WHITE);
        } else {
            pill.setBackground(TvV17Surface.rounded(0x22ffffff, a.dp(999), 0x2effffff, a.dp(1)));
            tv.setTextColor(0xebffffff);
        }
    }

    private void addFeatureCard(
            LinearLayout parent,
            int glyphKind,
            int accentColor,
            String titleStr,
            String descStr,
            boolean topMargin) {
        LinearLayout card = a.row();
        card.setGravity(Gravity.CENTER_VERTICAL);
        card.setPadding(a.dp(18), a.dp(16), a.dp(18), a.dp(16));
        card.setBackground(glassSurface(0x54141a28, 18, 0x22ffffff));

        FrameLayout iconWrap = new FrameLayout(a);
        iconWrap.setBackground(
                TvV17Surface.rounded(
                        (accentColor & 0x00ffffff) | 0x24000000, a.dp(13), 0x22ffffff, a.dp(1)));
        WelcomeGlyph glyph = new WelcomeGlyph(a, glyphKind, accentColor);
        iconWrap.addView(glyph, new FrameLayout.LayoutParams(-1, -1));
        LinearLayout.LayoutParams iLp = new LinearLayout.LayoutParams(a.dp(44), a.dp(44));
        iLp.rightMargin = a.dp(14);
        card.addView(iconWrap, iLp);

        LinearLayout copy = a.vertical();
        TextView t = a.text(titleStr, 14.5f, TvV17Theme.TEXT);
        t.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
        t.setSingleLine(true);
        t.setEllipsize(TextUtils.TruncateAt.END);
        copy.addView(t);

        TextView d = a.text(descStr, 12f, 0xa3ebebf5);
        d.setMaxLines(2);
        d.setEllipsize(TextUtils.TruncateAt.END);
        d.setLineSpacing(a.dp(3), 1f);
        d.setPadding(0, a.dp(4), 0, 0);
        copy.addView(d);

        card.addView(copy, new LinearLayout.LayoutParams(0, -2, 1f));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        if (topMargin) lp.topMargin = a.dp(12);
        parent.addView(card, lp);
    }

    private GradientDrawable glassSurface(int fill, float radiusDp, int stroke) {
        boolean reducedTrans =
                a.prefs != null && a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
        int bg = reducedTrans ? TvV17Theme.OPAQUE_SURFACE : fill;
        return TvV17Surface.rounded(bg, a.dp(radiusDp), stroke, a.dp(1));
    }

    /** Crisp resolution-independent vector glyphs for Welcome feature showcase cards. */
    private static final class WelcomeGlyph extends View {
        private final int kind;
        private final Paint stroke = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF box = new RectF();
        private final Path path = new Path();

        WelcomeGlyph(Context ctx, int kind, int tint) {
            super(ctx);
            this.kind = kind;
            stroke.setStyle(Paint.Style.STROKE);
            stroke.setStrokeCap(Paint.Cap.ROUND);
            stroke.setStrokeJoin(Paint.Join.ROUND);
            stroke.setColor(tint);
            fill.setStyle(Paint.Style.FILL);
            fill.setColor(tint);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth();
            int h = getHeight();
            if (w <= 0 || h <= 0) return;
            float s = Math.min(w, h);
            float cx = w * 0.5f;
            float cy = h * 0.5f;
            float r = s * 0.28f;
            stroke.setStrokeWidth(Math.max(2f, s * 0.055f));

            if (kind == GLYPH_QR) {
                float q = r * 0.85f;
                box.set(cx - q, cy - q, cx - q * 0.15f, cy - q * 0.15f);
                canvas.drawRoundRect(box, 3f, 3f, stroke);
                box.set(cx + q * 0.15f, cy - q, cx + q, cy - q * 0.15f);
                canvas.drawRoundRect(box, 3f, 3f, stroke);
                box.set(cx - q, cy + q * 0.15f, cx - q * 0.15f, cy + q);
                canvas.drawRoundRect(box, 3f, 3f, stroke);
                canvas.drawCircle(cx + q * 0.58f, cy + q * 0.58f, q * 0.24f, fill);
            } else if (kind == GLYPH_CINEMA) {
                box.set(cx - r * 1.1f, cy - r * 0.78f, cx + r * 1.1f, cy + r * 0.78f);
                canvas.drawRoundRect(box, r * 0.28f, r * 0.28f, stroke);
                path.reset();
                path.moveTo(cx - r * 0.25f, cy - r * 0.34f);
                path.lineTo(cx + r * 0.42f, cy);
                path.lineTo(cx - r * 0.25f, cy + r * 0.34f);
                path.close();
                canvas.drawPath(path, fill);
            } else {
                box.set(cx - r, cy - r, cx + r, cy + r);
                canvas.drawArc(box, -45f, 150f, false, stroke);
                canvas.drawArc(box, 135f, 150f, false, stroke);
                canvas.drawCircle(cx, cy, r * 0.22f, fill);
            }
        }
    }
}
