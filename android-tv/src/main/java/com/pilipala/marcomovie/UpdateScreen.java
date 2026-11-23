// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.*;
import android.graphics.drawable.GradientDrawable;
import android.media.MediaScannerConnection;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.OpenableColumns;
import android.provider.Settings;
import android.text.SpannableStringBuilder;
import android.text.Spanned;
import android.text.TextUtils;
import android.text.style.ForegroundColorSpan;
import android.text.style.StyleSpan;
import android.view.Gravity;
import android.view.View;
import android.widget.*;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * iOS Software Update (`通用 -> 软件更新`) inspired update center for Android Mobile and Android TV.
 * Prioritizes the mirror station for both metadata feeds and APK packages with automatic GitHub
 * fallback and SHA-256 + signature verification before installation.
 */
final class UpdateScreen {
    static final int INSTALL = 1401;
    final MainActivity a;
    final UpdateManager updates;
    TextView status;
    private TextView heroVersionTitle;
    private TextView heroMetaSubtitle;
    private TextView notesHeading;
    private TextView notesCountBadge;
    private TextView notesBody;
    private Button viewAllNotesBtn;
    private View progressWrap;
    private View progressFill;
    private TextView progressPercentView;
    private Button primaryBtn;
    private Button secondaryActionBtn;
    private TextView modeValueView;
    private String currentRawNotes = "";

    static final int TV_PREVIEW_MAX_ITEMS = 4;

    static final class PreviewNotes {
        final String overview;
        final List<String> previewItems;
        final int totalItems;
        final int hiddenItems;

        PreviewNotes(String overview, List<String> previewItems, int totalItems, int hiddenItems) {
            this.overview = overview == null ? "" : overview;
            this.previewItems = previewItems;
            this.totalItems = totalItems;
            this.hiddenItems = hiddenItems;
        }
    }

    static PreviewNotes buildPreviewData(String rawNotes, int maxItems) {
        int cap = Math.max(1, maxItems);
        ReleaseNotesFormatter.Summary summary = ReleaseNotesFormatter.summarize(rawNotes);
        List<String> all = new ArrayList<>();
        for (ReleaseNotesFormatter.Section sec : summary.sections) {
            for (String item : sec.items) {
                if (item != null && !item.trim().isEmpty()) {
                    all.add(item.trim());
                }
            }
        }
        if (all.isEmpty()) {
            String fallback =
                    !summary.overview.isEmpty()
                            ? summary.overview
                            : (rawNotes == null ? "" : rawNotes.trim());
            if (!fallback.isEmpty()) {
                all.add(fallback);
            }
        }
        int total = all.size();
        int shown = Math.min(cap, total);
        List<String> preview = new ArrayList<>(all.subList(0, shown));
        return new PreviewNotes(summary.overview, preview, total, Math.max(0, total - shown));
    }

    static String resolvePrimaryButtonLabel(
            boolean busy, boolean ready, String releaseVersion, boolean tvDevice) {
        if (busy) {
            return tvDevice ? "取消下载" : "正在处理… 取消任务";
        }
        if (ready && releaseVersion != null && !releaseVersion.trim().isEmpty()) {
            return tvDevice ? "立即安装 " + releaseVersion.trim() : "现在安装 " + releaseVersion.trim();
        }
        if (releaseVersion != null && !releaseVersion.trim().isEmpty()) {
            return tvDevice ? "立即下载" : "下载并更新 (" + releaseVersion.trim() + ")";
        }
        return "检查软件更新";
    }

    UpdateScreen(MainActivity host) {
        a = host;
        updates = UpdateManager.get(a);
    }

    private GradientDrawable cardSurface(
            int topColor, int bottomColor, float radiusDp, int stroke) {
        GradientDrawable d =
                new GradientDrawable(
                        GradientDrawable.Orientation.TOP_BOTTOM, new int[] {topColor, bottomColor});
        d.setCornerRadius(a.dp(radiusDp));
        if (stroke != 0) {
            d.setStroke(Math.max(1, a.dp(0.8f)), stroke);
        }
        return d;
    }

    void show() {
        a.renderPage("", "");
        a.updateScreen = this;
        boolean tv = a.isTvDevice();
        if (tv && a.body != null) {
            a.body.setPadding(a.dp(48), a.dp(24), a.dp(48), a.dp(28));
        }

        if (tv) {
            showTvLayout();
            return;
        }

        // Top Navigation Bar (Mobile)
        LinearLayout topNav = a.row();
        topNav.setGravity(Gravity.CENTER_VERTICAL);
        topNav.setPadding(0, 0, 0, a.dp(14));
        TextView backBtn = a.text("‹", 22, MainActivity.WHITE);
        backBtn.setGravity(Gravity.CENTER);
        backBtn.setBackground(
                MobileShell.glassBg(0xb034343a, 0xc01e1e22, a.dp(999), a.dp(0.8f), 0x38ffffff));
        MobileDetailScreen.bindTouchFeedback(backBtn);
        backBtn.setOnClickListener(v -> a.onBackPressed());
        LinearLayout.LayoutParams backLp = new LinearLayout.LayoutParams(a.dp(38), a.dp(38));
        backLp.rightMargin = a.dp(12);
        topNav.addView(backBtn, backLp);

        TextView heading = a.text("软件更新", 22, MainActivity.WHITE);
        heading.setTypeface(null, Typeface.BOLD);
        topNav.addView(heading, new LinearLayout.LayoutParams(0, -2, 1f));

        TextView mirrorBadge = a.text("镜像站优先", 11.5f, 0xff34d399);
        mirrorBadge.setTypeface(null, Typeface.BOLD);
        mirrorBadge.setPadding(a.dp(10), a.dp(4), a.dp(10), a.dp(4));
        mirrorBadge.setBackground(cardSurface(0x2630d158, 0x1a30d158, 999, 0x5534d399));
        topNav.addView(mirrorBadge, new LinearLayout.LayoutParams(-2, -2));
        a.body.addView(topNav, new LinearLayout.LayoutParams(-1, -2));

        // =====================================================================
        // 1. iOS SOFTWARE UPDATE HERO CARD
        // =====================================================================
        LinearLayout heroCard = a.vertical();
        heroCard.setPadding(a.dp(20), a.dp(20), a.dp(20), a.dp(20));
        heroCard.setBackground(cardSurface(0xd81c2421, 0xe6121816, 24, 0x2effffff));

        LinearLayout headerRow = a.row();
        headerRow.setGravity(Gravity.CENTER_VERTICAL);

        // App Squircle Icon Badge
        FrameLayout iconBox = new FrameLayout(a);
        GradientDrawable squircle =
                new GradientDrawable(
                        GradientDrawable.Orientation.TL_BR,
                        new int[] {0xff262a31, 0xff1d2025, 0xff14161a});
        squircle.setCornerRadius(a.dp(16));
        squircle.setStroke(Math.max(1, a.dp(1)), 0x38ffffff);
        iconBox.setBackground(squircle);
        ImageView logo = new ImageView(a);
        logo.setImageResource(R.drawable.logo_mark);
        FrameLayout.LayoutParams logoLp =
                new FrameLayout.LayoutParams(a.dp(36), a.dp(36), Gravity.CENTER);
        iconBox.addView(logo, logoLp);
        LinearLayout.LayoutParams iconLp = new LinearLayout.LayoutParams(a.dp(60), a.dp(60));
        iconLp.rightMargin = a.dp(16);
        headerRow.addView(iconBox, iconLp);

        LinearLayout titleCol = a.vertical();
        heroVersionTitle =
                a.text("Marco Movie " + UpdateManager.installedVersion(a), 19, MainActivity.WHITE);
        heroVersionTitle.setTypeface(null, Typeface.BOLD);
        titleCol.addView(heroVersionTitle);

        heroMetaSubtitle =
                a.text((tv ? "Android TV 端" : "Android 手机端") + " · 正式版渠道", 12.5f, 0xff9ca3af);
        heroMetaSubtitle.setPadding(0, a.dp(3), 0, 0);
        titleCol.addView(heroMetaSubtitle);

        status = a.text("", 13f, 0xff34d399);
        status.setTag("update-status");
        status.setPadding(0, a.dp(5), 0, 0);
        status.setLineSpacing(a.dp(2), 1f);
        titleCol.addView(status);

        headerRow.addView(titleCol, new LinearLayout.LayoutParams(0, -2, 1f));
        heroCard.addView(headerRow, new LinearLayout.LayoutParams(-1, -2));

        // Sleek iOS Download Progress Bar (shown when downloading / verifying)
        LinearLayout progContainer = a.vertical();
        progContainer.setPadding(0, a.dp(16), 0, 0);
        LinearLayout progLabelRow = a.row();
        progLabelRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView progTitle = a.text("正在优先从镜像站传输安装包…", 12, MainActivity.MUTED);
        progLabelRow.addView(progTitle, new LinearLayout.LayoutParams(0, -2, 1f));
        progressPercentView = a.text("0%", 12, 0xff5ac8fa);
        progressPercentView.setTypeface(null, Typeface.BOLD);
        progLabelRow.addView(progressPercentView, new LinearLayout.LayoutParams(-2, -2));
        progContainer.addView(progLabelRow, new LinearLayout.LayoutParams(-1, -2));
        a.gap(progContainer, 6);

        FrameLayout track = new FrameLayout(a);
        track.setBackground(a.bg(0x33ffffff, 999));
        progressFill = new View(a);
        progressFill.setBackground(a.bg(0xff0a84ff, 999));
        track.addView(progressFill, new FrameLayout.LayoutParams(0, a.dp(6), Gravity.LEFT));
        progContainer.addView(track, new LinearLayout.LayoutParams(-1, a.dp(6)));
        progressWrap = progContainer;
        progressWrap.setVisibility(View.GONE);
        heroCard.addView(progressWrap, new LinearLayout.LayoutParams(-1, -2));

        // Hairline Divider
        a.gap(heroCard, 16);
        View divider = new View(a);
        divider.setBackgroundColor(0x1fffffff);
        heroCard.addView(divider, new LinearLayout.LayoutParams(-1, Math.max(1, a.dp(0.7f))));
        a.gap(heroCard, 14);

        // Release Notes / Feature Highlights Box
        notesHeading = a.text("关于此更新", 13.5f, MainActivity.WHITE);
        notesHeading.setTypeface(null, Typeface.BOLD);
        heroCard.addView(notesHeading);
        a.gap(heroCard, 6);

        notesBody = a.text("", 13f, 0xffd1d5db);
        notesBody.setTag("update-notes");
        notesBody.setId(View.generateViewId());
        notesBody.setFocusable(tv);
        notesBody.setFocusableInTouchMode(tv);
        if (tv) notesBody.setContentDescription("更新内容，按上下键逐段阅读");
        notesBody.setLineSpacing(a.dp(4), 1f);
        heroCard.addView(notesBody, new LinearLayout.LayoutParams(-1, -2));

        a.gap(heroCard, 18);

        // Primary & Secondary Action Buttons Row
        LinearLayout actionRow = a.row();
        actionRow.setGravity(Gravity.CENTER_VERTICAL);

        primaryBtn =
                a.button(
                        "检查软件更新",
                        "update-check",
                        () -> {
                            if (updates.busy) {
                                updates.cancel();
                            } else if (updates.ready()) {
                                install();
                            } else if (updates.available != null) {
                                updates.download();
                            } else {
                                updates.check(true);
                            }
                        });
        primaryBtn.setFocusable(true);
        primaryBtn.setTextSize(14.5f);
        primaryBtn.setTypeface(null, Typeface.BOLD);
        primaryBtn.setTextColor(MainActivity.WHITE);
        primaryBtn.setMinHeight(a.dp(46));
        primaryBtn.setMinimumHeight(a.dp(46));
        primaryBtn.setBackground(a.bg(0xff0a84ff, 14));
        primaryBtn.setOnFocusChangeListener(
                (v, f) ->
                        FocusMotion.style(
                                a,
                                primaryBtn,
                                f,
                                0xff0a84ff,
                                MainActivity.WHITE,
                                14,
                                MainActivity.WHITE,
                                MainActivity.DARK,
                                false,
                                1.02f));
        actionRow.addView(primaryBtn, new LinearLayout.LayoutParams(0, a.dp(46), 1f));

        secondaryActionBtn =
                a.button(
                        "重新检查",
                        "update-secondary",
                        () -> {
                            if (updates.busy) {
                                updates.cancel();
                            } else {
                                updates.check(true);
                            }
                        });
        secondaryActionBtn.setFocusable(true);
        secondaryActionBtn.setTextSize(13.5f);
        secondaryActionBtn.setTextColor(0xffe5e7eb);
        secondaryActionBtn.setMinHeight(a.dp(46));
        secondaryActionBtn.setMinimumHeight(a.dp(46));
        secondaryActionBtn.setPadding(a.dp(16), 0, a.dp(16), 0);
        secondaryActionBtn.setBackground(cardSurface(0xff26312d, 0xff1c2522, 14, 0x2effffff));
        secondaryActionBtn.setOnFocusChangeListener(
                (v, f) ->
                        FocusMotion.style(
                                a,
                                secondaryActionBtn,
                                f,
                                0xff26312d,
                                MainActivity.WHITE,
                                14,
                                0xffe5e7eb,
                                MainActivity.DARK,
                                false,
                                1.02f));
        LinearLayout.LayoutParams secLp = new LinearLayout.LayoutParams(-2, a.dp(46));
        secLp.leftMargin = a.dp(10);
        actionRow.addView(secondaryActionBtn, secLp);

        heroCard.addView(actionRow, new LinearLayout.LayoutParams(-1, -2));
        a.body.addView(heroCard, new LinearLayout.LayoutParams(-1, -2));

        a.gap(a.body, 16);

        // =====================================================================
        // 2. iOS INSET-GROUPED SETTINGS CARD (Automatic Updates & Mirror Policy)
        // =====================================================================
        LinearLayout groupCard = a.vertical();
        groupCard.setBackground(cardSurface(0xb81b2320, 0xb8131917, 20, 0x26ffffff));

        // Row 1: Automatic Update Mode
        LinearLayout modeRow = a.row();
        modeRow.setTag("update-mode");
        modeRow.setGravity(Gravity.CENTER_VERTICAL);
        modeRow.setPadding(a.dp(18), a.dp(16), a.dp(18), a.dp(16));
        modeRow.setClickable(true);
        modeRow.setFocusable(tv);
        modeRow.setFocusableInTouchMode(tv);
        if (tv) {
            modeRow.setOnFocusChangeListener(
                    (v, f) ->
                            FocusMotion.style(
                                    a,
                                    modeRow,
                                    f,
                                    0x00000000,
                                    0x28ffffff,
                                    16,
                                    MainActivity.WHITE,
                                    MainActivity.WHITE,
                                    true,
                                    1.005f));
        } else {
            MobileShell.bindCardTouchFeedback(
                    a, modeRow, null, cardSurface(0x28ffffff, 0x18ffffff, 20, 0));
        }
        TextView modeTitle = a.text("自动更新策略", 15f, MainActivity.WHITE);
        modeTitle.setTypeface(null, Typeface.BOLD);
        modeRow.addView(modeTitle, new LinearLayout.LayoutParams(0, -2, 1f));
        modeValueView = a.text(modeName(updates.mode()) + "  ›", 13.5f, MainActivity.MUTED);
        modeRow.addView(modeValueView, new LinearLayout.LayoutParams(-2, -2));
        modeRow.setOnClickListener(
                v -> {
                    if (!tv) {
                        String[] modes = {"notify", "download", "off"};
                        String[] labels = {"自动检查并提醒（推荐）", "自动下载后提醒", "仅手动检查"};
                        int cur =
                                Math.max(0, java.util.Arrays.asList(modes).indexOf(updates.mode()));
                        MobileShell.showDrawerPicker(
                                a,
                                "自动更新策略",
                                "自动检查至少间隔六小时，播放过程中绝不弹窗打扰",
                                labels,
                                cur,
                                idx -> {
                                    updates.setMode(modes[idx]);
                                    refresh();
                                });
                    } else {
                        mode();
                    }
                });
        groupCard.addView(modeRow, new LinearLayout.LayoutParams(-1, -2));

        View rowDiv1 = new View(a);
        rowDiv1.setBackgroundColor(0x16ffffff);
        LinearLayout.LayoutParams divLp1 =
                new LinearLayout.LayoutParams(-1, Math.max(1, a.dp(0.6f)));
        divLp1.leftMargin = a.dp(18);
        divLp1.rightMargin = a.dp(18);
        groupCard.addView(rowDiv1, divLp1);

        // Row 2: Manual Install Ready Package (if downloaded) or Release Notes Dialog
        LinearLayout installRow = a.row();
        installRow.setTag("update-install");
        installRow.setGravity(Gravity.CENTER_VERTICAL);
        installRow.setPadding(a.dp(18), a.dp(16), a.dp(18), a.dp(16));
        installRow.setClickable(true);
        installRow.setFocusable(tv);
        installRow.setFocusableInTouchMode(tv);
        if (tv) {
            installRow.setOnFocusChangeListener(
                    (v, f) ->
                            FocusMotion.style(
                                    a,
                                    installRow,
                                    f,
                                    0x00000000,
                                    0x28ffffff,
                                    16,
                                    MainActivity.WHITE,
                                    MainActivity.WHITE,
                                    true,
                                    1.005f));
        } else {
            MobileShell.bindCardTouchFeedback(
                    a, installRow, null, cardSurface(0x28ffffff, 0x18ffffff, 20, 0));
        }
        TextView installTitle = a.text("安装已下载更新包", 15f, MainActivity.WHITE);
        installTitle.setTypeface(null, Typeface.BOLD);
        installRow.addView(installTitle, new LinearLayout.LayoutParams(0, -2, 1f));
        TextView installHint = a.text("覆盖升级保留全部数据  ›", 13f, MainActivity.MUTED);
        installRow.addView(installHint, new LinearLayout.LayoutParams(-2, -2));
        installRow.setOnClickListener(v -> install());
        groupCard.addView(installRow, new LinearLayout.LayoutParams(-1, -2));

        View rowDiv2 = new View(a);
        rowDiv2.setBackgroundColor(0x16ffffff);
        LinearLayout.LayoutParams divLp2 =
                new LinearLayout.LayoutParams(-1, Math.max(1, a.dp(0.6f)));
        divLp2.leftMargin = a.dp(18);
        divLp2.rightMargin = a.dp(18);
        groupCard.addView(rowDiv2, divLp2);

        // Row 3: Mirror Source Priority Info
        LinearLayout sourceRow = a.row();
        sourceRow.setGravity(Gravity.CENTER_VERTICAL);
        sourceRow.setPadding(a.dp(18), a.dp(16), a.dp(18), a.dp(16));
        TextView sourceTitle = a.text("下载线路优先级", 15f, MainActivity.WHITE);
        sourceTitle.setTypeface(null, Typeface.BOLD);
        sourceRow.addView(sourceTitle, new LinearLayout.LayoutParams(0, -2, 1f));
        TextView sourceVal = a.text("镜像站优先 · GitHub 备用", 13f, 0xff34d399);
        sourceRow.addView(sourceVal, new LinearLayout.LayoutParams(-2, -2));
        groupCard.addView(sourceRow, new LinearLayout.LayoutParams(-1, -2));

        a.body.addView(groupCard, new LinearLayout.LayoutParams(-1, -2));

        a.gap(a.body, 14);
        TextView footer =
                a.text(
                        "各平台版本独立推进。检查更新与下载安装包均优先连接镜像站（marcotv.wlj9919.top），不可用时自动无缝回退至 GitHub 官方源。安装前自动核验 SHA-256 摘要与开发者签名。",
                        12f,
                        MainActivity.MUTED);
        footer.setPadding(a.dp(6), 0, a.dp(6), a.dp(16));
        footer.setLineSpacing(a.dp(3), 1f);
        a.body.addView(footer, new LinearLayout.LayoutParams(-1, -2));

        refresh();
    }

    private void showTvLayout() {
        notesCountBadge = null;
        viewAllNotesBtn = null;

        // Compact Top Title Bar
        LinearLayout titleRow = a.row();
        titleRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView heading = a.text("软件更新", 28, MainActivity.WHITE);
        heading.setTypeface(null, Typeface.BOLD);
        titleRow.addView(heading, new LinearLayout.LayoutParams(0, -2, 1f));

        TextView mirrorBadge = a.text("镜像站优先 · 自动校验签名", 12f, 0xff34d399);
        mirrorBadge.setTypeface(null, Typeface.BOLD);
        mirrorBadge.setPadding(a.dp(12), a.dp(5), a.dp(12), a.dp(5));
        mirrorBadge.setBackground(cardSurface(0x2630d158, 0x1a30d158, 999, 0x5534d399));
        titleRow.addView(mirrorBadge, new LinearLayout.LayoutParams(-2, -2));
        a.body.addView(titleRow, new LinearLayout.LayoutParams(-1, -2));
        a.gap(a.body, 16);

        // Two-Column Living-Room Dashboard: Left = Version & Actions, Right = Compact Changelog
        LinearLayout splitRow = a.row();
        splitRow.setGravity(Gravity.TOP);
        splitRow.setClipChildren(false);
        splitRow.setClipToPadding(false);

        // LEFT COLUMN: Hero Version + Status + Download Progress + Primary CTA
        LinearLayout leftCard = a.vertical();
        leftCard.setTag("update-tv-hero");
        leftCard.setPadding(a.dp(22), a.dp(20), a.dp(22), a.dp(20));
        leftCard.setBackground(cardSurface(0xd81c2421, 0xe6121816, 22, 0x2effffff));

        LinearLayout headerRow = a.row();
        headerRow.setGravity(Gravity.CENTER_VERTICAL);
        FrameLayout iconBox = new FrameLayout(a);
        GradientDrawable squircle =
                new GradientDrawable(
                        GradientDrawable.Orientation.TL_BR,
                        new int[] {0xff262a31, 0xff1d2025, 0xff14161a});
        squircle.setCornerRadius(a.dp(15));
        squircle.setStroke(Math.max(1, a.dp(1)), 0x38ffffff);
        iconBox.setBackground(squircle);
        ImageView logo = new ImageView(a);
        logo.setImageResource(R.drawable.logo_mark);
        iconBox.addView(logo, new FrameLayout.LayoutParams(a.dp(34), a.dp(34), Gravity.CENTER));
        LinearLayout.LayoutParams iconLp = new LinearLayout.LayoutParams(a.dp(56), a.dp(56));
        iconLp.rightMargin = a.dp(14);
        headerRow.addView(iconBox, iconLp);

        LinearLayout titleCol = a.vertical();
        heroVersionTitle =
                a.text("Marco Movie " + UpdateManager.installedVersion(a), 19, MainActivity.WHITE);
        heroVersionTitle.setTypeface(null, Typeface.BOLD);
        heroVersionTitle.setSingleLine(true);
        heroVersionTitle.setEllipsize(TextUtils.TruncateAt.END);
        titleCol.addView(heroVersionTitle);

        heroMetaSubtitle = a.text("Android TV 端 · 正式版渠道", 12.5f, 0xff9ca3af);
        heroMetaSubtitle.setPadding(0, a.dp(3), 0, 0);
        heroMetaSubtitle.setSingleLine(true);
        heroMetaSubtitle.setEllipsize(TextUtils.TruncateAt.END);
        titleCol.addView(heroMetaSubtitle);
        headerRow.addView(titleCol, new LinearLayout.LayoutParams(0, -2, 1f));
        leftCard.addView(headerRow, new LinearLayout.LayoutParams(-1, -2));

        status = a.text("", 12.5f, 0xff34d399);
        status.setTag("update-status");
        status.setPadding(0, a.dp(12), 0, 0);
        status.setLineSpacing(a.dp(3), 1f);
        leftCard.addView(status, new LinearLayout.LayoutParams(-1, -2));

        // Download progress bar (shown when busy && percent >= 0)
        LinearLayout progContainer = a.vertical();
        progContainer.setPadding(0, a.dp(14), 0, 0);
        LinearLayout progLabelRow = a.row();
        progLabelRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView progTitle = a.text("正在传输安装包…", 12, MainActivity.MUTED);
        progLabelRow.addView(progTitle, new LinearLayout.LayoutParams(0, -2, 1f));
        progressPercentView = a.text("0%", 12, 0xff5ac8fa);
        progressPercentView.setTypeface(null, Typeface.BOLD);
        progLabelRow.addView(progressPercentView, new LinearLayout.LayoutParams(-2, -2));
        progContainer.addView(progLabelRow, new LinearLayout.LayoutParams(-1, -2));
        a.gap(progContainer, 6);
        FrameLayout track = new FrameLayout(a);
        track.setBackground(a.bg(0x33ffffff, 999));
        progressFill = new View(a);
        progressFill.setBackground(a.bg(0xff0a84ff, 999));
        track.addView(progressFill, new FrameLayout.LayoutParams(0, a.dp(6), Gravity.LEFT));
        progContainer.addView(track, new LinearLayout.LayoutParams(-1, a.dp(6)));
        progressWrap = progContainer;
        progressWrap.setVisibility(View.GONE);
        leftCard.addView(progressWrap, new LinearLayout.LayoutParams(-1, -2));

        a.gap(leftCard, 18);

        // Primary Action Button ("立即下载" when update available)
        primaryBtn =
                a.button(
                        "检查软件更新",
                        "update-check",
                        () -> {
                            if (updates.busy) {
                                updates.cancel();
                            } else if (updates.ready()) {
                                install();
                            } else if (updates.available != null) {
                                updates.download();
                            } else {
                                updates.check(true);
                            }
                        });
        primaryBtn.setId(View.generateViewId());
        primaryBtn.setFocusable(true);
        primaryBtn.setFocusableInTouchMode(true);
        primaryBtn.setTextSize(15f);
        primaryBtn.setTypeface(null, Typeface.BOLD);
        primaryBtn.setTextColor(MainActivity.WHITE);
        primaryBtn.setMinHeight(a.dp(46));
        primaryBtn.setMinimumHeight(a.dp(46));
        primaryBtn.setBackground(a.bg(0xff0a84ff, 14));
        primaryBtn.setOnFocusChangeListener(
                (v, f) ->
                        FocusMotion.style(
                                a,
                                primaryBtn,
                                f,
                                0xff0a84ff,
                                MainActivity.WHITE,
                                14,
                                MainActivity.WHITE,
                                MainActivity.DARK,
                                false,
                                1.025f));
        leftCard.addView(primaryBtn, new LinearLayout.LayoutParams(-1, a.dp(46)));

        secondaryActionBtn =
                a.button(
                        "重新检查",
                        "update-secondary",
                        () -> {
                            if (updates.busy) {
                                updates.cancel();
                            } else {
                                updates.check(true);
                            }
                        });
        secondaryActionBtn.setId(View.generateViewId());
        secondaryActionBtn.setFocusable(true);
        secondaryActionBtn.setFocusableInTouchMode(true);
        secondaryActionBtn.setTextSize(13.5f);
        secondaryActionBtn.setTextColor(0xffe5e7eb);
        secondaryActionBtn.setMinHeight(a.dp(42));
        secondaryActionBtn.setMinimumHeight(a.dp(42));
        secondaryActionBtn.setBackground(cardSurface(0xff26312d, 0xff1c2522, 14, 0x2effffff));
        secondaryActionBtn.setOnFocusChangeListener(
                (v, f) ->
                        FocusMotion.style(
                                a,
                                secondaryActionBtn,
                                f,
                                0xff26312d,
                                MainActivity.WHITE,
                                14,
                                0xffe5e7eb,
                                MainActivity.DARK,
                                false,
                                1.02f));
        LinearLayout.LayoutParams secLp = new LinearLayout.LayoutParams(-1, a.dp(42));
        secLp.topMargin = a.dp(10);
        leftCard.addView(secondaryActionBtn, secLp);

        LinearLayout.LayoutParams leftLp = new LinearLayout.LayoutParams(0, -2, 0.45f);
        leftLp.rightMargin = a.dp(18);
        splitRow.addView(leftCard, leftLp);

        // RIGHT COLUMN: Condensed Changelog Preview + "查看全部更新内容" Button
        LinearLayout rightCard = a.vertical();
        rightCard.setTag("update-tv-notes-card");
        rightCard.setPadding(a.dp(22), a.dp(20), a.dp(22), a.dp(20));
        rightCard.setBackground(cardSurface(0xc8171d24, 0xd812171d, 22, 0x26ffffff));

        LinearLayout notesHeader = a.row();
        notesHeader.setGravity(Gravity.CENTER_VERTICAL);
        notesHeading = a.text("更新亮点", 15.5f, MainActivity.WHITE);
        notesHeading.setTypeface(null, Typeface.BOLD);
        notesHeader.addView(notesHeading, new LinearLayout.LayoutParams(0, -2, 1f));

        notesCountBadge = a.text("", 11.5f, 0xff5ac8fa);
        notesCountBadge.setTypeface(null, Typeface.BOLD);
        notesCountBadge.setPadding(a.dp(10), a.dp(3), a.dp(10), a.dp(3));
        notesCountBadge.setBackground(cardSurface(0x225ac8fa, 0x165ac8fa, 999, 0x445ac8fa));
        notesCountBadge.setVisibility(View.GONE);
        notesHeader.addView(notesCountBadge, new LinearLayout.LayoutParams(-2, -2));
        rightCard.addView(notesHeader, new LinearLayout.LayoutParams(-1, -2));

        a.gap(rightCard, 12);
        View rightDiv = new View(a);
        rightDiv.setBackgroundColor(0x1cffffff);
        rightCard.addView(rightDiv, new LinearLayout.LayoutParams(-1, Math.max(1, a.dp(0.7f))));
        a.gap(rightCard, 12);

        notesBody = a.text("", 13.5f, 0xffd1d5db);
        notesBody.setTag("update-notes");
        notesBody.setFocusable(false);
        notesBody.setFocusableInTouchMode(false);
        notesBody.setLineSpacing(a.dp(5), 1f);
        notesBody.setMaxLines(8);
        notesBody.setEllipsize(TextUtils.TruncateAt.END);
        rightCard.addView(notesBody, new LinearLayout.LayoutParams(-1, -2));

        a.gap(rightCard, 16);

        viewAllNotesBtn =
                a.button("查看全部更新内容  ›", "update-view-all-notes", this::showFullReleaseNotesDialog);
        viewAllNotesBtn.setId(View.generateViewId());
        viewAllNotesBtn.setFocusable(true);
        viewAllNotesBtn.setFocusableInTouchMode(true);
        viewAllNotesBtn.setTextSize(13.5f);
        viewAllNotesBtn.setTypeface(null, Typeface.BOLD);
        viewAllNotesBtn.setTextColor(0xffe5e7eb);
        viewAllNotesBtn.setMinHeight(a.dp(42));
        viewAllNotesBtn.setMinimumHeight(a.dp(42));
        viewAllNotesBtn.setBackground(cardSurface(0x28ffffff, 0x18ffffff, 14, 0x36ffffff));
        viewAllNotesBtn.setOnFocusChangeListener(
                (v, f) ->
                        FocusMotion.style(
                                a,
                                viewAllNotesBtn,
                                f,
                                0x26ffffff,
                                MainActivity.WHITE,
                                14,
                                0xffe5e7eb,
                                MainActivity.DARK,
                                false,
                                1.02f));
        rightCard.addView(viewAllNotesBtn, new LinearLayout.LayoutParams(-1, a.dp(42)));

        splitRow.addView(rightCard, new LinearLayout.LayoutParams(0, -2, 0.55f));
        a.body.addView(splitRow, new LinearLayout.LayoutParams(-1, -2));

        a.gap(a.body, 16);

        // Compact Bottom Settings Strip (fits comfortably on 1080p/720p single screen)
        LinearLayout bottomStrip = a.row();
        bottomStrip.setGravity(Gravity.CENTER_VERTICAL);
        bottomStrip.setPadding(a.dp(10), a.dp(10), a.dp(10), a.dp(10));
        bottomStrip.setBackground(cardSurface(0xb81b2320, 0xb8131917, 18, 0x24ffffff));

        LinearLayout modeRow = a.row();
        modeRow.setId(View.generateViewId());
        modeRow.setTag("update-mode");
        modeRow.setGravity(Gravity.CENTER_VERTICAL);
        modeRow.setPadding(a.dp(14), a.dp(12), a.dp(14), a.dp(12));
        modeRow.setClickable(true);
        modeRow.setFocusable(true);
        modeRow.setFocusableInTouchMode(true);
        modeRow.setOnFocusChangeListener(
                (v, f) ->
                        FocusMotion.style(
                                a,
                                modeRow,
                                f,
                                0x00000000,
                                0x28ffffff,
                                12,
                                MainActivity.WHITE,
                                MainActivity.WHITE,
                                true,
                                1.01f));
        TextView modeTitle = a.text("自动更新策略", 13.5f, MainActivity.WHITE);
        modeTitle.setTypeface(null, Typeface.BOLD);
        modeRow.addView(modeTitle, new LinearLayout.LayoutParams(0, -2, 1f));
        modeValueView = a.text(modeName(updates.mode()) + "  ›", 12.5f, MainActivity.MUTED);
        modeRow.addView(modeValueView, new LinearLayout.LayoutParams(-2, -2));
        modeRow.setOnClickListener(v -> mode());
        LinearLayout.LayoutParams modeLp = new LinearLayout.LayoutParams(0, -2, 1f);
        modeLp.rightMargin = a.dp(8);
        bottomStrip.addView(modeRow, modeLp);

        LinearLayout installRow = a.row();
        installRow.setId(View.generateViewId());
        installRow.setTag("update-install");
        installRow.setGravity(Gravity.CENTER_VERTICAL);
        installRow.setPadding(a.dp(14), a.dp(12), a.dp(14), a.dp(12));
        installRow.setClickable(true);
        installRow.setFocusable(true);
        installRow.setFocusableInTouchMode(true);
        installRow.setOnFocusChangeListener(
                (v, f) ->
                        FocusMotion.style(
                                a,
                                installRow,
                                f,
                                0x00000000,
                                0x28ffffff,
                                12,
                                MainActivity.WHITE,
                                MainActivity.WHITE,
                                true,
                                1.01f));
        TextView installTitle = a.text("安装已下载更新包", 13.5f, MainActivity.WHITE);
        installTitle.setTypeface(null, Typeface.BOLD);
        installRow.addView(installTitle, new LinearLayout.LayoutParams(0, -2, 1f));
        TextView installHint = a.text("覆盖保留数据  ›", 12.5f, MainActivity.MUTED);
        installRow.addView(installHint, new LinearLayout.LayoutParams(-2, -2));
        installRow.setOnClickListener(v -> install());
        LinearLayout.LayoutParams instLp = new LinearLayout.LayoutParams(0, -2, 1f);
        instLp.rightMargin = a.dp(8);
        bottomStrip.addView(installRow, instLp);

        TextView sourceVal = a.text("线路：镜像站优先 · GitHub 备用", 12f, 0xff34d399);
        sourceVal.setPadding(a.dp(10), 0, a.dp(10), 0);
        bottomStrip.addView(sourceVal, new LinearLayout.LayoutParams(-2, -2));

        a.body.addView(bottomStrip, new LinearLayout.LayoutParams(-1, -2));

        // Explicit D-pad focus choreography & guaranteed initial focus on primary CTA ("立即下载")
        primaryBtn.setNextFocusRightId(viewAllNotesBtn.getId());
        secondaryActionBtn.setNextFocusRightId(viewAllNotesBtn.getId());
        secondaryActionBtn.setNextFocusUpId(primaryBtn.getId());
        secondaryActionBtn.setNextFocusDownId(modeRow.getId());
        viewAllNotesBtn.setNextFocusLeftId(primaryBtn.getId());
        viewAllNotesBtn.setNextFocusDownId(installRow.getId());
        modeRow.setNextFocusRightId(installRow.getId());
        installRow.setNextFocusLeftId(modeRow.getId());
        installRow.setNextFocusUpId(viewAllNotesBtn.getId());

        a.tvInitialFocus = primaryBtn;
        refresh();
        if (a.current == null || a.current.focus == null || a.current.focus.isEmpty()) {
            primaryBtn.requestFocus();
        }
    }

    private void showFullReleaseNotesDialog() {
        UpdateManager.Release rel = updates.available;
        String versionTitle =
                rel != null && rel.version != null && !rel.version.trim().isEmpty()
                        ? "版本 " + rel.version + " 完整更新内容"
                        : "版本特性与安全保障";
        CharSequence fullNotes =
                (currentRawNotes != null && !currentRawNotes.trim().isEmpty())
                        ? buildStyledNotes(currentRawNotes)
                        : ("• 镜像站优先加速：检查更新与下载 APK 均优先拉取镜像站资源，异常时自动切换 GitHub\n"
                                + "• 平台独立演进：手机端与电视端按各自平台节奏独立发布版本号\n"
                                + "• 完整性与签名保护：安装前严格校验 SHA-256 与应用签名，覆盖升级保留全部片源配置与历史记录");
        TextView body = a.text("", 14f, 0xffe5e7eb);
        body.setText(fullNotes);
        body.setLineSpacing(a.dp(5), 1f);
        body.setFocusable(a.isTvDevice());
        body.setFocusableInTouchMode(a.isTvDevice());
        body.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(8));
        new AppDialog.Builder(a)
                .setTitle(versionTitle)
                .setWide(true)
                .setView(body)
                .setPositiveButton("关闭", null)
                .show();
    }

    void refresh() {
        String installedVer = UpdateManager.installedVersion(a);
        boolean tv = a.isTvDevice();
        String platformLabel = tv ? "Android TV 端" : "Android 手机端";
        UpdateManager.Release rel = updates.available;

        if (status != null) {
            status.setText(
                    "当前版本 "
                            + installedVer
                            + " · 正式版\n"
                            + updates.message
                            + (updates.percent >= 0 ? " · " + updates.percent + "%" : "")
                            + "\n"
                            + modeName(updates.mode()));
            if (updates.ready() || (rel == null && !updates.busy)) {
                status.setTextColor(0xff34d399);
            } else if (updates.busy) {
                status.setTextColor(0xff5ac8fa);
            } else {
                status.setTextColor(0xfffbbf24);
            }
        }

        if (heroVersionTitle != null) {
            if (rel != null) {
                heroVersionTitle.setText("Marco Movie " + rel.version);
            } else {
                heroVersionTitle.setText("Marco Movie " + installedVer);
            }
        }

        if (heroMetaSubtitle != null) {
            if (rel != null && rel.size > 0) {
                String sizeMb = String.format(Locale.US, "%.1f MB", rel.size / (1024f * 1024f));
                heroMetaSubtitle.setText(platformLabel + " · 新版本可用 · " + sizeMb);
            } else {
                heroMetaSubtitle.setText(platformLabel + " · 已安装当前版本 " + installedVer);
            }
        }

        if (progressWrap != null && progressFill != null && progressPercentView != null) {
            if (updates.busy && updates.percent >= 0) {
                progressWrap.setVisibility(View.VISIBLE);
                int pct = Math.max(0, Math.min(100, updates.percent));
                progressPercentView.setText(pct + "%");
                View parent = (View) progressFill.getParent();
                int totalW =
                        parent != null && parent.getWidth() > 0
                                ? parent.getWidth()
                                : (a.windowWidth() - a.dp(80));
                FrameLayout.LayoutParams lp =
                        (FrameLayout.LayoutParams) progressFill.getLayoutParams();
                lp.width = Math.max(a.dp(8), Math.round(totalW * (pct / 100f)));
                progressFill.setLayoutParams(lp);
            } else {
                progressWrap.setVisibility(View.GONE);
            }
        }

        currentRawNotes = (rel != null && rel.notes != null) ? rel.notes : "";
        if (notesHeading != null && notesBody != null) {
            if (rel != null && rel.notes != null && !rel.notes.trim().isEmpty()) {
                if (tv) {
                    PreviewNotes preview = buildPreviewData(rel.notes, TV_PREVIEW_MAX_ITEMS);
                    notesHeading.setText("版本 " + rel.version + " 更新亮点");
                    if (notesCountBadge != null) {
                        notesCountBadge.setText("共 " + preview.totalItems + " 项");
                        notesCountBadge.setVisibility(
                                preview.totalItems > 0 ? View.VISIBLE : View.GONE);
                    }
                    notesBody.setText(buildStyledPreviewNotes(preview));
                    if (viewAllNotesBtn != null) {
                        viewAllNotesBtn.setText(
                                preview.hiddenItems > 0
                                        ? "查看全部更新内容（共 " + preview.totalItems + " 项） ›"
                                        : "查看完整更新日志  ›");
                        viewAllNotesBtn.setVisibility(View.VISIBLE);
                    }
                } else {
                    notesHeading.setText("版本 " + rel.version + " 更新摘要");
                    notesBody.setText(buildStyledNotes(rel.notes));
                }
            } else {
                notesHeading.setText("版本特性与安全保障");
                if (notesCountBadge != null) {
                    notesCountBadge.setVisibility(View.GONE);
                }
                notesBody.setText(
                        "• 镜像站优先加速：检查更新与下载 APK 均优先拉取镜像站资源，异常时自动切换 GitHub\n"
                                + "• 平台独立演进：手机端与电视端按各自平台节奏独立发布版本号\n"
                                + "• 完整性与签名保护：安装前严格校验 SHA-256 与应用签名，覆盖升级保留全部片源配置与历史记录");
                if (viewAllNotesBtn != null) {
                    viewAllNotesBtn.setText("查看更新说明详情  ›");
                    viewAllNotesBtn.setVisibility(View.VISIBLE);
                }
            }
        }

        if (primaryBtn != null && secondaryActionBtn != null) {
            String relVer = rel != null ? rel.version : null;
            primaryBtn.setText(
                    resolvePrimaryButtonLabel(updates.busy, updates.ready(), relVer, tv));
            if (updates.busy) {
                secondaryActionBtn.setVisibility(View.GONE);
            } else if (rel != null) {
                secondaryActionBtn.setText("重新检查");
                secondaryActionBtn.setVisibility(View.VISIBLE);
            } else {
                secondaryActionBtn.setVisibility(View.GONE);
            }
        }

        if (modeValueView != null) {
            modeValueView.setText(modeName(updates.mode()) + "  ›");
        }
    }

    static CharSequence buildStyledPreviewNotes(PreviewNotes preview) {
        if (preview == null || preview.previewItems.isEmpty()) {
            return preview != null ? preview.overview : "";
        }
        SpannableStringBuilder sb = new SpannableStringBuilder();
        for (int i = 0; i < preview.previewItems.size(); i++) {
            String item = preview.previewItems.get(i);
            sb.append("• ");
            int colon = item.indexOf('：');
            if (colon > 0 && colon <= 24) {
                int bStart = sb.length();
                sb.append(item.substring(0, colon + 1));
                sb.setSpan(
                        new StyleSpan(Typeface.BOLD),
                        bStart,
                        sb.length(),
                        Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.setSpan(
                        new ForegroundColorSpan(MainActivity.WHITE),
                        bStart,
                        sb.length(),
                        Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.append(item.substring(colon + 1));
            } else {
                sb.append(item);
            }
            if (i + 1 < preview.previewItems.size()) {
                sb.append("\n");
            }
        }
        if (preview.hiddenItems > 0) {
            sb.append("\n\n");
            int hStart = sb.length();
            sb.append("已收纳其余 ")
                    .append(String.valueOf(preview.hiddenItems))
                    .append(" 项更新内容，点击下方按钮查看完整日志");
            sb.setSpan(
                    new ForegroundColorSpan(0xff9ca3af),
                    hStart,
                    sb.length(),
                    Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        }
        return sb;
    }

    static CharSequence buildStyledNotes(String rawNotes) {
        ReleaseNotesFormatter.Summary summary = ReleaseNotesFormatter.summarize(rawNotes);
        if (summary.sections.isEmpty()) {
            return summary.overview.isEmpty() ? rawNotes.trim() : summary.overview;
        }
        SpannableStringBuilder sb = new SpannableStringBuilder();
        if (!summary.overview.isEmpty()) {
            int start = sb.length();
            sb.append(summary.overview);
            sb.setSpan(
                    new ForegroundColorSpan(0xffe5e7eb),
                    start,
                    sb.length(),
                    Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            sb.append("\n\n");
        } else if (summary.totalItems >= 2) {
            int start = sb.length();
            sb.append("共整理 ").append(String.valueOf(summary.totalItems)).append(" 项重点升级改进");
            sb.setSpan(
                    new ForegroundColorSpan(0xff9ca3af),
                    start,
                    sb.length(),
                    Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            sb.append("\n\n");
        }
        boolean showHeaders = summary.sections.size() > 1 || summary.totalItems >= 3;
        for (int i = 0; i < summary.sections.size(); i++) {
            ReleaseNotesFormatter.Section sec = summary.sections.get(i);
            if (showHeaders) {
                int hStart = sb.length();
                sb.append("▎ ").append(sec.title);
                sb.setSpan(
                        new StyleSpan(Typeface.BOLD),
                        hStart,
                        sb.length(),
                        Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.setSpan(
                        new ForegroundColorSpan(0xff5ac8fa),
                        hStart,
                        sb.length(),
                        Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                sb.append("\n");
            }
            for (String item : sec.items) {
                sb.append("• ");
                int colon = item.indexOf('：');
                if (colon > 0 && colon <= 24) {
                    int bStart = sb.length();
                    sb.append(item.substring(0, colon + 1));
                    sb.setSpan(
                            new StyleSpan(Typeface.BOLD),
                            bStart,
                            sb.length(),
                            Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                    sb.setSpan(
                            new ForegroundColorSpan(MainActivity.WHITE),
                            bStart,
                            sb.length(),
                            Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                    sb.append(item.substring(colon + 1));
                } else {
                    sb.append(item);
                }
                sb.append("\n");
            }
            if (i + 1 < summary.sections.size()) {
                sb.append("\n");
            }
        }
        while (sb.length() > 0 && sb.charAt(sb.length() - 1) == '\n') {
            sb.delete(sb.length() - 1, sb.length());
        }
        return sb;
    }

    static String modeName(String mode) {
        return "off".equals(mode) ? "仅手动检查" : "download".equals(mode) ? "自动下载后提醒" : "自动检查并提醒";
    }

    void mode() {
        String[] modes = {"notify", "download", "off"};
        new AppDialog.Builder(a)
                .setTitle("更新方式")
                .setMessage("自动检查至少间隔六小时，仅在应用首页运行时发起。播放过程中不弹出更新窗口；安装始终由你确认。")
                .setSingleChoiceItems(
                        new String[] {"自动检查并提醒", "自动下载后提醒", "仅手动检查"},
                        java.util.Arrays.asList(modes).indexOf(updates.mode()),
                        (d, n) -> {
                            updates.setMode(modes[n]);
                            refresh();
                        })
                .setNegativeButton("返回", null)
                .show();
    }

    static final String XIAOMI_TV_SECURITY_ACTION = "com.xiaomi.mitv.settings.SECURITY_SETTINGS";

    static boolean canRequestPackageInstallsCompat(Context c) {
        if (Build.VERSION.SDK_INT < 26) return true;
        if (c == null || c.getPackageManager() == null) return false;
        try {
            return c.getPackageManager().canRequestPackageInstalls();
        } catch (RuntimeException ignored) {
            return false;
        }
    }

    /**
     * Pure-JVM fallback order for opening unknown-app installation settings across Android phones,
     * standard Android TV, and OEM TVs (such as Xiaomi HyperOS TV / MiTV) that strip AOSP's
     * per-app {@code ACTION_MANAGE_UNKNOWN_APP_SOURCES} activity.
     */
    static List<String> unknownSourcesSettingsActionOrder(boolean tvDevice) {
        List<String> actions = new ArrayList<String>();
        actions.add(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES + "|package");
        actions.add(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES);
        if (tvDevice) {
            actions.add(XIAOMI_TV_SECURITY_ACTION);
        }
        actions.add(Settings.ACTION_SECURITY_SETTINGS);
        actions.add(Settings.ACTION_APPLICATION_DETAILS_SETTINGS + "|package");
        actions.add(Settings.ACTION_SETTINGS);
        return actions;
    }

    static List<Intent> unknownSourcesSettingsFallbacks(String packageName, boolean tvDevice) {
        String pkg = packageName == null ? "" : packageName.trim();
        Uri pkgUri = pkg.isEmpty() ? null : Uri.parse("package:" + pkg);
        List<Intent> out = new ArrayList<Intent>();
        if (pkgUri != null) {
            out.add(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, pkgUri));
        }
        out.add(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES));
        if (tvDevice) {
            out.add(new Intent(XIAOMI_TV_SECURITY_ACTION));
        }
        out.add(new Intent(Settings.ACTION_SECURITY_SETTINGS));
        if (pkgUri != null) {
            out.add(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkgUri));
        }
        out.add(new Intent(Settings.ACTION_SETTINGS));
        return out;
    }

    static boolean hasUnknownSourcesSettingsActivity(PackageManager pm, String packageName) {
        if (pm == null) return false;
        String pkg = packageName == null ? "" : packageName.trim();
        if (!pkg.isEmpty()) {
            Intent withPkg =
                    new Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:" + pkg));
            if (pm.resolveActivity(withPkg, 0) != null) return true;
        }
        Intent generic = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES);
        return pm.resolveActivity(generic, 0) != null;
    }

    /**
     * Pure-JVM installer action order: API 29+ prioritizes {@code ACTION_VIEW} (since {@code
     * ACTION_INSTALL_PACKAGE} is deprecated on Android 10+ and blocked on some HyperOS/Android 12+
     * TVs), while API 23-28 retains {@code ACTION_INSTALL_PACKAGE} first with {@code ACTION_VIEW}
     * fallback.
     */
    static List<String> installActionOrder(int sdkInt) {
        List<String> order = new ArrayList<String>();
        if (sdkInt >= 29) {
            order.add(Intent.ACTION_VIEW);
            order.add(Intent.ACTION_INSTALL_PACKAGE);
        } else {
            order.add(Intent.ACTION_INSTALL_PACKAGE);
            order.add(Intent.ACTION_VIEW);
        }
        return order;
    }

    static String exportApkFileName(String version, boolean tvDevice) {
        String cleanVer = version == null ? "" : version.replaceAll("[^0-9A-Za-z._-]", "");
        while (cleanVer.contains("..")) {
            cleanVer = cleanVer.replace("..", "");
        }
        while (cleanVer.startsWith(".") || cleanVer.startsWith("-")) {
            cleanVer = cleanVer.substring(1);
        }
        while (cleanVer.endsWith(".") || cleanVer.endsWith("-")) {
            cleanVer = cleanVer.substring(0, cleanVer.length() - 1);
        }
        if (cleanVer.isEmpty()) cleanVer = "update";
        return "MarcoMovie-" + cleanVer + (tvDevice ? "-android-tv.apk" : "-android-mobile.apk");
    }

    private boolean openUnknownSourcesSettings() {
        List<Intent> candidates =
                unknownSourcesSettingsFallbacks(a.getPackageName(), a.isTvDevice());
        for (Intent intent : candidates) {
            try {
                if (a.getPackageManager().resolveActivity(intent, 0) == null) continue;
                a.startActivity(intent);
                return true;
            } catch (RuntimeException ignored) {
            }
        }
        for (Intent intent : candidates) {
            try {
                a.startActivity(intent);
                return true;
            } catch (RuntimeException ignored) {
            }
        }
        return false;
    }

    static boolean shouldPreferDirectInstallOnTv(
            boolean tvDevice, boolean canRequestPackageInstalls) {
        return tvDevice && !canRequestPackageInstalls;
    }

    void install() {
        if (updates.busy) {
            a.toast("请等待当前任务完成");
            return;
        }
        if (!updates.ready()) {
            a.toast("请先下载并校验新版");
            return;
        }
        String deviceName = a.isTvDevice() ? "电视" : "手机";
        if (!canRequestPackageInstallsCompat(a)) {
            boolean hasPerAppSettings =
                    hasUnknownSourcesSettingsActivity(a.getPackageManager(), a.getPackageName());
            if (shouldPreferDirectInstallOnTv(a.isTvDevice(), false)) {
                // OEM Android TV ROMs (Android 9/11 Xiaomi/Hisense/TCL/etc.) often expose a stub or
                // non-functional MANAGE_UNKNOWN_APP_SOURCES page while allowing global unknown
                // sources or local media-center APK installs. Always make direct install primary
                // and keep both Settings & Save-to-Downloads one click away!
                AppDialog dlg =
                        new AppDialog.Builder(a)
                                .setTitle("安装 " + updates.available.version)
                                .setMessage(
                                        hasPerAppSettings
                                                ? "可先点击「直接尝试安装」；若电视系统拦截安装，可点击「打开授权页面」开启允许未知来源，或点击「保存到本机下载」后在电视媒体中心/电视管家中安装。"
                                                : "该电视未提供应用级安装授权页（如小米澎湃 OS 电视）。可先点「确认安装」；若系统拦截，请前往「设置 → 账号与安全 → 安装未知来源的应用」开启允许，或点击「保存到本机下载」后在电视「媒体中心 / 电视管家」中直接安装。")
                                .setPositiveButton(
                                        hasPerAppSettings ? "直接尝试安装" : "确认安装",
                                        (d, n) -> prepareInstall())
                                .setNeutralButton(
                                        hasPerAppSettings ? "打开授权页面" : "打开安全设置",
                                        (d, n) -> {
                                            if (!openUnknownSourcesSettings()) {
                                                a.notice(
                                                        "请使用遥控器打开电视「设置 → 账号与安全 → 安装未知来源的应用」并设为允许。");
                                            }
                                        })
                                .setNegativeButton(
                                        "保存到本机下载", (d, n) -> exportVerifiedApkToDownloads())
                                .setDefaultFocusButton(DialogInterface.BUTTON_POSITIVE)
                                .show();
                Button pos = dlg.getButton(DialogInterface.BUTTON_POSITIVE);
                if (pos != null) pos.requestFocus();
            } else if (hasPerAppSettings) {
                AppDialog dlg =
                        new AppDialog.Builder(a)
                                .setTitle("允许安装更新")
                                .setMessage(
                                        deviceName
                                                + "需要允许 Marco Movie 安装应用。打开系统授权后返回本页再次点击安装；若已在系统安全设置中开启全局未知来源，也可直接尝试安装。")
                                .setPositiveButton(
                                        "打开授权页面",
                                        (d, n) -> {
                                            if (!openUnknownSourcesSettings()) {
                                                a.notice("当前设备未提供授权页面，请前往系统设置开启未知来源安装，或直接尝试安装。");
                                            }
                                        })
                                .setNeutralButton("直接尝试安装", (d, n) -> prepareInstall())
                                .setNegativeButton("稍后", null)
                                .setDefaultFocusButton(DialogInterface.BUTTON_POSITIVE)
                                .show();
                Button pos = dlg.getButton(DialogInterface.BUTTON_POSITIVE);
                if (pos != null) pos.requestFocus();
            } else {
                AppDialog dlg =
                        new AppDialog.Builder(a)
                                .setTitle("安装 " + updates.available.version)
                                .setMessage("当前系统未提供应用级安装授权页，可先点击「确认安装」，或点击「保存到本机下载」后在文件管理器中安装。")
                                .setPositiveButton("确认安装", (d, n) -> prepareInstall())
                                .setNeutralButton(
                                        "打开安全设置",
                                        (d, n) -> {
                                            if (!openUnknownSourcesSettings()) {
                                                a.notice("请前往系统安全设置开启未知来源应用安装。");
                                            }
                                        })
                                .setNegativeButton(
                                        "保存到本机下载", (d, n) -> exportVerifiedApkToDownloads())
                                .setDefaultFocusButton(DialogInterface.BUTTON_POSITIVE)
                                .show();
                Button pos = dlg.getButton(DialogInterface.BUTTON_POSITIVE);
                if (pos != null) pos.requestFocus();
            }
            return;
        }
        AppDialog confirmDlg =
                new AppDialog.Builder(a)
                        .setTitle("安装 " + updates.available.version + "？")
                        .setMessage("将打开系统的安装确认页面。覆盖升级保留配置、收藏和观看记录。")
                        .setPositiveButton("确认安装", (d, n) -> prepareInstall())
                        .setNegativeButton("稍后", null)
                        .setDefaultFocusButton(DialogInterface.BUTTON_POSITIVE)
                        .show();
        Button confirmBtn = confirmDlg.getButton(DialogInterface.BUTTON_POSITIVE);
        if (confirmBtn != null) confirmBtn.requestFocus();
    }

    static Intent installIntent() {
        Intent intent =
                new Intent(Intent.ACTION_INSTALL_PACKAGE)
                        .setDataAndType(
                                UpdateApkProvider.URI, "application/vnd.android.package-archive")
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        .putExtra(Intent.EXTRA_RETURN_RESULT, true);
        intent.setClipData(ClipData.newRawUri("Marco Movie update", UpdateApkProvider.URI));
        return intent;
    }

    static Intent viewInstallIntent() {
        Intent intent =
                new Intent(Intent.ACTION_VIEW)
                        .setDataAndType(
                                UpdateApkProvider.URI, "application/vnd.android.package-archive")
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        intent.setClipData(ClipData.newRawUri("Marco Movie update", UpdateApkProvider.URI));
        return intent;
    }

    private boolean launchSystemInstaller() {
        List<String> order = installActionOrder(Build.VERSION.SDK_INT);
        for (String action : order) {
            Intent intent =
                    Intent.ACTION_VIEW.equals(action) ? viewInstallIntent() : installIntent();
            try {
                a.startActivityForResult(intent, INSTALL);
                return true;
            } catch (RuntimeException ignored) {
            }
        }
        try {
            Intent detached = viewInstallIntent().addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            a.startActivity(detached);
            return true;
        } catch (RuntimeException ignored) {
            return false;
        }
    }

    private void showInstallBlockedDialog() {
        new AppDialog.Builder(a)
                .setTitle("电视系统限制了应用内直接安装")
                .setMessage(
                        "当前电视系统拒绝直接拉起安装器。请确认已在「设置 → 账号与安全」开启「安装未知来源的应用」；也可将已校验的新版安装包保存到本机 Download 目录，直接在电视自带的「媒体中心 / 高清播放器 / 电视管家」中点击安装（无需 U 盘或电脑）。")
                .setPositiveButton("保存到本机下载", (d, n) -> exportVerifiedApkToDownloads())
                .setNeutralButton(
                        "打开安全设置",
                        (d, n) -> {
                            if (!openUnknownSourcesSettings()) {
                                a.notice("请前往电视「设置 → 账号与安全 → 安装未知来源的应用」开启允许。");
                            }
                        })
                .setNegativeButton("关闭", null)
                .show();
    }

    private void exportVerifiedApkToDownloads() {
        final UpdateManager.Release release = updates.available;
        if (release == null || updates.busy) return;
        final int epoch = a.generation;
        updates.busy = true;
        updates.resetCancellation();
        updates.message = "正在校验并保存到本机下载目录…";
        refresh();
        updates.worker.execute(
                () -> {
                    try {
                        File apkFile = updates.apk();
                        UpdateManager.verifyApk(a, apkFile, release);
                        String fileName = exportApkFileName(release.version, a.isTvDevice());
                        String savedPath = saveApkToPublicDownloads(a, apkFile, fileName);
                        a.ui.post(
                                () -> {
                                    updates.busy = false;
                                    updates.message = "安装包已保存到 " + savedPath;
                                    refresh();
                                    if (!a.isFinishing() && epoch == a.generation) {
                                        new AppDialog.Builder(a)
                                                .setTitle("已保存到本机下载目录")
                                                .setMessage(
                                                        "保存位置："
                                                                + savedPath
                                                                + "\n\n请打开电视自带的「媒体中心 / 高清播放器 / 文件管理 / 电视管家」，在「下载 (Download)」文件夹中点击该安装包即可覆盖升级（无需 U 盘或电脑，配置与观看记录全部保留）。")
                                                .setPositiveButton("知道了", null)
                                                .show();
                                    }
                                });
                    } catch (final Exception error) {
                        a.ui.post(
                                () -> {
                                    updates.busy = false;
                                    updates.message = "保存安装包失败，请检查存储权限或使用 U 盘 / 局域网安装";
                                    refresh();
                                    a.notice("保存到本机下载目录失败：" + a.message(error));
                                });
                    }
                });
    }

    private static String saveApkToPublicDownloads(Context ctx, File srcApk, String fileName)
            throws IOException {
        if (Build.VERSION.SDK_INT >= 29) {
            try {
                ContentValues cv = new ContentValues();
                cv.put(OpenableColumns.DISPLAY_NAME, fileName);
                cv.put("mime_type", "application/vnd.android.package-archive");
                cv.put("relative_path", Environment.DIRECTORY_DOWNLOADS + "/MarcoMovie");
                Uri target =
                        ctx.getContentResolver()
                                .insert(Uri.parse("content://media/external/downloads"), cv);
                if (target != null) {
                    try (InputStream in = new FileInputStream(srcApk);
                            OutputStream out = ctx.getContentResolver().openOutputStream(target)) {
                        if (out == null) throw new IOException("无法写入系统下载目录");
                        copyStream(in, out);
                        return "Download/MarcoMovie/" + fileName;
                    } catch (IOException | RuntimeException e) {
                        try {
                            ctx.getContentResolver().delete(target, null, null);
                        } catch (RuntimeException ignored) {
                        }
                        throw e;
                    }
                }
            } catch (Exception ignored) {
                // Fall through to legacy Download directory on OEM TVs without MediaStore Downloads
            }
        }
        File downloadsDir =
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
        if (downloadsDir != null && (downloadsDir.isDirectory() || downloadsDir.mkdirs())) {
            File outFile = new File(downloadsDir, fileName);
            try {
                try (InputStream in = new FileInputStream(srcApk);
                        OutputStream out = new FileOutputStream(outFile)) {
                    copyStream(in, out);
                }
                try {
                    MediaScannerConnection.scanFile(
                            ctx,
                            new String[] {outFile.getAbsolutePath()},
                            new String[] {"application/vnd.android.package-archive"},
                            null);
                } catch (RuntimeException ignored) {
                }
                return "Download/" + fileName;
            } catch (IOException | SecurityException ignored) {
                // Fall back to app-scoped external Download directory when legacy storage is denied
            }
        }
        File appExternal = ctx.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS);
        if (appExternal != null && (appExternal.isDirectory() || appExternal.mkdirs())) {
            File outFile = new File(appExternal, fileName);
            try (InputStream in = new FileInputStream(srcApk);
                    OutputStream out = new FileOutputStream(outFile)) {
                copyStream(in, out);
            }
            return outFile.getAbsolutePath();
        }
        throw new IOException("系统 Download 目录不可写");
    }

    private static void copyStream(InputStream in, OutputStream out) throws IOException {
        byte[] buf = new byte[32768];
        int n;
        while ((n = in.read(buf)) != -1) {
            out.write(buf, 0, n);
        }
        out.flush();
    }

    void prepareInstall() {
        final UpdateManager.Release release = updates.available;
        if (release == null || updates.busy) return;
        final int epoch = a.generation;
        updates.busy = true;
        updates.resetCancellation();
        updates.message = "正在核对安装包…";
        refresh();
        updates.worker.execute(
                () -> {
                    try {
                        UpdateManager.verifyApk(a, updates.apk(), release);
                        a.ui.post(
                                () -> {
                                    updates.busy = false;
                                    if (!a.foreground
                                            || a.isFinishing()
                                            || a.isDestroyed()
                                            || epoch != a.generation
                                            || updates.cancelled()
                                            || status == null
                                            || !status.isAttachedToWindow()) {
                                        updates.message = "校验完成，回到软件更新页后可继续安装";
                                        return;
                                    }
                                    updates.prefs
                                            .edit()
                                            .putInt("pending_code", release.code)
                                            .apply();
                                    if (launchSystemInstaller()) {
                                        updates.message = "请在系统安装页面确认或返回";
                                    } else {
                                        updates.prefs.edit().remove("pending_code").apply();
                                        updates.message = "电视系统拦截了直接安装，可保存到本机下载目录安装";
                                        showInstallBlockedDialog();
                                    }
                                    refresh();
                                });
                    } catch (Exception error) {
                        a.ui.post(
                                () -> {
                                    updates.busy = false;
                                    updates.message = "安装包校验失败，请重新下载";
                                    refresh();
                                });
                    }
                });
    }

    static void result(MainActivity a) {
        UpdateManager updates = UpdateManager.get(a);
        updates.prefs.edit().remove("pending_code").apply();
        boolean tvUnverifiedInstall =
                a.isTvDevice() && !canRequestPackageInstallsCompat(a) && updates.ready();
        if (tvUnverifiedInstall) {
            updates.message = "系统未完成安装。可确认「电视设置 → 账号与安全 → 安装未知来源的应用」已开启，或选择「保存到本机下载」后在电视媒体中心安装";
            if (a.updateScreen != null) {
                a.updateScreen.refresh();
                a.updateScreen.showInstallBlockedDialog();
                return;
            }
        } else {
            updates.message = "已返回应用；若取消安装，原版本继续保留";
        }
        if (a.updateScreen != null) a.updateScreen.refresh();
    }
}
