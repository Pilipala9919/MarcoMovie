// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.content.Intent;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Apple tvOS-style Local USB Hard Drive Poster Wall screen for Android TV. Automatically detects
 * mounted external drives, scans videos, groups movies & TV series, scrapes posters online (or
 * extracts offline video thumbnails), and launches native TV detail & playback screens.
 */
final class TvLocalDriveScreen {
    private static final int FILTER_ALL = 0;
    private static final int FILTER_MOVIES = 1;
    private static final int FILTER_SERIES = 2;

    private final MainActivity a;
    private List<LocalDriveScanner.DriveRoot> drives = new ArrayList<>();
    private List<LocalMediaLibrary.LocalVideoItem> allItems = new ArrayList<>();
    private String selectedDriveId = "";
    private int selectedFilter = FILTER_ALL;

    private TextView summaryBadge;
    private TextView statusLine;
    private LinearLayout controlsHost;
    private LinearLayout gridHost;
    private final Map<String, ImageView> posterViewsById = new HashMap<>();
    private final Map<String, TextView> badgeViewsById = new HashMap<>();
    private int screenTicket;

    TvLocalDriveScreen(MainActivity activity) {
        this.a = activity;
    }

    void show() {
        a.renderPage("", "");
        screenTicket = a.generation;
        if (a.body != null) {
            a.body.setPadding(a.dp(48), a.dp(24), a.dp(48), a.dp(44));
        }

        renderHeaderBar();
        a.gap(a.body, 14);

        controlsHost = a.vertical();
        controlsHost.setClipChildren(false);
        controlsHost.setClipToPadding(false);
        a.body.addView(controlsHost, new LinearLayout.LayoutParams(-1, -2));

        statusLine = a.text("正在检测已挂载的移动硬盘…", 13f, 0xb8ebebf5);
        statusLine.setPadding(a.dp(4), a.dp(10), a.dp(4), a.dp(12));
        a.body.addView(statusLine, new LinearLayout.LayoutParams(-1, -2));

        gridHost = a.vertical();
        gridHost.setClipChildren(false);
        gridHost.setClipToPadding(false);
        a.body.addView(gridHost, new LinearLayout.LayoutParams(-1, -2));

        // Load cached library immediately for instant display, then run fresh USB scan
        allItems = new ArrayList<>(LocalMediaLibrary.loadCache(a));
        drives = LocalDriveScanner.discoverDrives(a);
        renderControlStrip();
        if (!allItems.isEmpty()) {
            renderPosterWall();
        }
        startDriveScan(false);
    }

    private void renderHeaderBar() {
        LinearLayout header = a.row();
        header.setGravity(Gravity.CENTER_VERTICAL);

        TextView heading = a.text("移动硬盘", 30, TvV17Theme.TEXT);
        heading.setTypeface(null, Typeface.BOLD);
        header.addView(heading, new LinearLayout.LayoutParams(-2, -2));

        summaryBadge = a.text("本地影视海报墙", 12, 0xccebebf5);
        summaryBadge.setTypeface(null, Typeface.BOLD);
        summaryBadge.setPadding(a.dp(12), a.dp(5), a.dp(12), a.dp(5));
        summaryBadge.setBackground(
                TvV17Surface.rounded(0x22ffffff, a.dp(999), 0x2a818cf8, a.dp(1)));
        LinearLayout.LayoutParams pillLp = new LinearLayout.LayoutParams(-2, -2);
        pillLp.leftMargin = a.dp(14);
        header.addView(summaryBadge, pillLp);

        header.addView(new View(a), new LinearLayout.LayoutParams(0, 1, 1f));

        String clockText = new SimpleDateFormat("HH:mm", Locale.getDefault()).format(new Date());
        TextView clock = a.text(clockText, 15.5f, 0xb8ebebf5);
        clock.setTypeface(null, Typeface.BOLD);
        header.addView(clock);
        a.body.addView(header, new LinearLayout.LayoutParams(-1, -2));
    }

    private void renderControlStrip() {
        controlsHost.removeAllViews();

        // Row 1: Drives & Actions
        HorizontalScrollView scroll = new HorizontalScrollView(a);
        scroll.setHorizontalScrollBarEnabled(false);
        scroll.setClipChildren(false);
        scroll.setClipToPadding(false);
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setClipChildren(false);
        row.setClipToPadding(false);
        row.setPadding(a.dp(2), a.dp(4), a.dp(2), a.dp(6));

        addPill(
                row,
                "全部硬盘 (" + drives.size() + ")",
                "local-drive:all",
                selectedDriveId.isEmpty(),
                () -> {
                    selectedDriveId = "";
                    renderControlStrip();
                    renderPosterWall();
                });

        for (final LocalDriveScanner.DriveRoot d : drives) {
            boolean active = d.id.equals(selectedDriveId);
            String label =
                    d.label
                            + (d.totalBytes > 0
                                    ? " · " + LocalDriveScanner.formatBytes(d.totalBytes)
                                    : "");
            addPill(
                    row,
                    label,
                    "local-drive:" + d.id,
                    active,
                    () -> {
                        selectedDriveId = d.id;
                        renderControlStrip();
                        renderPosterWall();
                    });
        }

        // Visual separator
        View sep = new View(a);
        sep.setBackgroundColor(0x28ffffff);
        LinearLayout.LayoutParams sepLp =
                new LinearLayout.LayoutParams(Math.max(1, a.dp(1)), a.dp(22));
        sepLp.leftMargin = a.dp(6);
        sepLp.rightMargin = a.dp(14);
        row.addView(sep, sepLp);

        // Filter pills
        addPill(
                row,
                "全部",
                "local-filter:all",
                selectedFilter == FILTER_ALL,
                () -> {
                    selectedFilter = FILTER_ALL;
                    renderControlStrip();
                    renderPosterWall();
                });
        addPill(
                row,
                "电影",
                "local-filter:movies",
                selectedFilter == FILTER_MOVIES,
                () -> {
                    selectedFilter = FILTER_MOVIES;
                    renderControlStrip();
                    renderPosterWall();
                });
        addPill(
                row,
                "剧集",
                "local-filter:series",
                selectedFilter == FILTER_SERIES,
                () -> {
                    selectedFilter = FILTER_SERIES;
                    renderControlStrip();
                    renderPosterWall();
                });

        // Action pills
        Button rescanBtn =
                addPill(row, "🔄 重新扫描", "local-action:rescan", false, () -> startDriveScan(true));
        addPill(row, "📂 添加目录", "local-action:add-dir", false, this::openDirectoryPicker);
        if (!a.hasFullStoragePermission()) {
            addPill(
                    row,
                    "🔐 开启存储权限",
                    "local-action:permission",
                    false,
                    a::openTvStoragePermissionSettings);
        }

        scroll.addView(row, new FrameLayout.LayoutParams(-2, -2));
        controlsHost.addView(scroll, new LinearLayout.LayoutParams(-1, -2));

        if (a.tvInitialFocus == null) {
            a.tvInitialFocus = rescanBtn;
        }
    }

    private Button addPill(
            LinearLayout parent, String label, String tag, final boolean active, Runnable action) {
        final Button btn = a.button(label, tag, action);
        btn.setId(View.generateViewId());
        btn.setSingleLine(true);
        btn.setEllipsize(TextUtils.TruncateAt.END);
        btn.setTextSize(13f);
        btn.setMinHeight(a.dp(36));
        btn.setMinimumHeight(a.dp(36));
        btn.setPadding(a.dp(15), a.dp(6), a.dp(15), a.dp(6));
        stylePill(btn, false, active);
        btn.setOnFocusChangeListener((v, f) -> stylePill(btn, f, active));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, a.dp(36));
        lp.rightMargin = a.dp(8);
        parent.addView(btn, lp);
        return btn;
    }

    private void stylePill(Button btn, boolean focused, boolean active) {
        int bg = focused ? 0xf8ffffff : (active ? 0x38818cf8 : 0x20ffffff);
        int stroke = focused ? 0xffffffff : (active ? 0x88818cf8 : 0x26ffffff);
        btn.setBackground(TvV17Surface.rounded(bg, a.dp(18), stroke, Math.max(1, a.dp(1))));
        btn.setTextColor(focused ? 0xff0d1016 : (active ? Color.WHITE : 0xdcebebf5));
        float scale = focused ? (a.reduced ? 1f : 1.035f) : 1f;
        btn.setScaleX(scale);
        btn.setScaleY(scale);
    }

    private void startDriveScan(final boolean forceRescrape) {
        final int ticket = screenTicket;
        if (statusLine != null) {
            statusLine.setText("正在扫描已接入的移动硬盘与影视文件…");
            statusLine.setVisibility(View.VISIBLE);
        }
        a.worker.execute(
                () -> {
                    final List<LocalDriveScanner.DriveRoot> detected =
                            LocalDriveScanner.discoverDrives(a);
                    List<LocalDriveScanner.ScannedFile> scanned = new ArrayList<>();
                    for (LocalDriveScanner.DriveRoot d : detected) {
                        scanned.addAll(LocalDriveScanner.scanDrive(a, d));
                    }

                    Map<String, LocalMediaLibrary.LocalVideoItem> existingMap = new HashMap<>();
                    if (!forceRescrape) {
                        for (LocalMediaLibrary.LocalVideoItem old :
                                LocalMediaLibrary.loadCache(a)) {
                            existingMap.put(old.id, old);
                        }
                    }

                    final List<LocalMediaLibrary.LocalVideoItem> grouped =
                            LocalMediaLibrary.groupScannedFiles(scanned, existingMap);
                    LocalMediaLibrary.saveCache(a, grouped);

                    a.ui.post(
                            () -> {
                                if (a.isFinishing() || ticket != a.generation) return;
                                drives = detected;
                                allItems = grouped;
                                updateSummaryBadge();
                                renderControlStrip();
                                renderPosterWall();

                                if (grouped.isEmpty()) {
                                    if (!a.hasFullStoragePermission()) {
                                        statusLine.setText("未读取到硬盘文件：请先点击「开启存储权限」或「添加目录」授权访问移动硬盘。");
                                    } else if (detected.isEmpty()) {
                                        statusLine.setText(
                                                "暂未检测到外接移动硬盘 / U 盘。插入后点击「重新扫描」，或点击「添加目录」手动选取。");
                                    } else {
                                        statusLine.setText(
                                                "已检测到 "
                                                        + detected.size()
                                                        + " 个外接硬盘，但未找到大于 10MB 的常见视频文件。");
                                    }
                                    return;
                                }

                                int unscraped = 0;
                                for (LocalMediaLibrary.LocalVideoItem it : grouped) {
                                    if (!it.scrapedOnline || it.posterUrl.isEmpty()) unscraped++;
                                }
                                if (unscraped > 0) {
                                    statusLine.setText(
                                            "已发现 "
                                                    + grouped.size()
                                                    + " 部本地影视，正在自动刮削海报墙（剩余 "
                                                    + unscraped
                                                    + " 部）…");
                                    LocalMediaScraper.scrapeMissingAsync(
                                            a,
                                            grouped,
                                            ticket,
                                            a,
                                            new LocalMediaScraper.ProgressCallback() {
                                                @Override
                                                public void onItemScraped(
                                                        LocalMediaLibrary.LocalVideoItem item,
                                                        int completed,
                                                        int total) {
                                                    if (ticket != a.generation) return;
                                                    ImageView iv = posterViewsById.get(item.id);
                                                    if (iv != null && !item.posterUrl.isEmpty()) {
                                                        ImageLoader.poster(
                                                                a, item.posterUrl, iv, false);
                                                    }
                                                    TextView bv = badgeViewsById.get(item.id);
                                                    if (bv != null && item.doubanScore > 0.1) {
                                                        bv.setText(
                                                                String.format(
                                                                        Locale.US,
                                                                        "豆 %.1f",
                                                                        item.doubanScore));
                                                        bv.setVisibility(View.VISIBLE);
                                                    }
                                                    statusLine.setText(
                                                            "正在自动生成海报墙："
                                                                    + completed
                                                                    + " / "
                                                                    + total);
                                                }

                                                @Override
                                                public void onAllComplete(
                                                        List<LocalMediaLibrary.LocalVideoItem>
                                                                items) {
                                                    if (ticket != a.generation) return;
                                                    statusLine.setText(
                                                            "海报墙已就绪 · 共 "
                                                                    + items.size()
                                                                    + " 部本地影视（点击海报即可播放或手动微调刮削）");
                                                }
                                            });
                                } else {
                                    statusLine.setText(
                                            "海报墙已就绪 · 共 "
                                                    + grouped.size()
                                                    + " 部本地影视（来自 "
                                                    + Math.max(1, detected.size())
                                                    + " 个外接存储）");
                                }
                            });
                });
    }

    private void updateSummaryBadge() {
        if (summaryBadge == null) return;
        int movies = 0;
        int series = 0;
        for (LocalMediaLibrary.LocalVideoItem item : allItems) {
            if (item.isSeries) series++;
            else movies++;
        }
        summaryBadge.setText(
                drives.size()
                        + " 个硬盘 · "
                        + allItems.size()
                        + " 部（电影 "
                        + movies
                        + " / 剧集 "
                        + series
                        + "）");
    }

    private List<LocalMediaLibrary.LocalVideoItem> filteredItems() {
        List<LocalMediaLibrary.LocalVideoItem> list = new ArrayList<>();
        for (LocalMediaLibrary.LocalVideoItem item : allItems) {
            if (!selectedDriveId.isEmpty() && !selectedDriveId.equals(item.driveId)) continue;
            if (selectedFilter == FILTER_MOVIES && item.isSeries) continue;
            if (selectedFilter == FILTER_SERIES && !item.isSeries) continue;
            list.add(item);
        }
        return list;
    }

    private void renderPosterWall() {
        gridHost.removeAllViews();
        posterViewsById.clear();
        badgeViewsById.clear();

        List<LocalMediaLibrary.LocalVideoItem> items = filteredItems();
        if (items.isEmpty()) {
            LinearLayout emptyBox = a.vertical();
            emptyBox.setGravity(Gravity.CENTER);
            emptyBox.setPadding(a.dp(32), a.dp(36), a.dp(32), a.dp(36));
            emptyBox.setBackground(
                    TvV17Surface.rounded(0x4d151b26, a.dp(20), 0x22ffffff, Math.max(1, a.dp(1))));

            TextView title =
                    a.text(drives.isEmpty() ? "请接入移动硬盘或 U 盘" : "当前筛选下暂无本地影视", 18f, TvV17Theme.TEXT);
            title.setTypeface(null, Typeface.BOLD);
            emptyBox.addView(title);

            TextView sub =
                    a.text(
                            "支持自动扫描 MP4 / MKV / AVI / TS / RMVB 等本地影片与外挂字幕，自动识别电影与剧集并生成高清海报墙。",
                            13.5f,
                            0xa8ebebf5);
            sub.setGravity(Gravity.CENTER);
            sub.setPadding(0, a.dp(10), 0, a.dp(18));
            emptyBox.addView(sub);

            LinearLayout btnRow = a.row();
            btnRow.setGravity(Gravity.CENTER);
            Button primary =
                    addPill(
                            btnRow,
                            "🔄 立即扫描硬盘",
                            "local-empty-rescan",
                            true,
                            () -> startDriveScan(true));
            addPill(btnRow, "📂 手动选择目录", "local-empty-add", false, this::openDirectoryPicker);
            if (!a.hasFullStoragePermission()) {
                addPill(
                        btnRow,
                        "🔐 开启全部文件权限",
                        "local-empty-perm",
                        false,
                        a::openTvStoragePermissionSettings);
            }
            emptyBox.addView(btnRow, new LinearLayout.LayoutParams(-2, -2));
            gridHost.addView(emptyBox, new LinearLayout.LayoutParams(-1, -2));
            a.tvInitialFocus = primary;
            return;
        }

        float density = Math.max(1f, a.getResources().getDisplayMetrics().density);
        int cols = TvLayoutPolicy.homeColumns(a.windowWidth() / density, 6);
        cols = Math.max(4, Math.min(7, cols));
        int gap = a.dp(16);
        int posterW = Math.max(a.dp(120), (a.windowWidth() - a.dp(96) - gap * (cols - 1)) / cols);
        int posterH = Math.round(posterW * 1.48f);

        View firstCard = null;
        LinearLayout row = null;
        for (int i = 0; i < items.size(); i++) {
            if (i % cols == 0) {
                row = a.row();
                row.setGravity(Gravity.TOP);
                row.setClipChildren(false);
                row.setClipToPadding(false);
                LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(-1, -2);
                rlp.bottomMargin = a.dp(20);
                gridHost.addView(row, rlp);
            }
            final LocalMediaLibrary.LocalVideoItem item = items.get(i);
            View card = buildPosterCard(item, posterW, posterH);
            if (firstCard == null) firstCard = card;
            LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(0, -2, 1f);
            if (i % cols < cols - 1) clp.rightMargin = gap;
            row.addView(card, clp);
        }
        if (row != null) {
            int rem = items.size() % cols;
            if (rem > 0) {
                for (int k = rem; k < cols; k++) {
                    View spacer = new View(a);
                    LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(0, 1, 1f);
                    if (k < cols - 1) slp.rightMargin = gap;
                    row.addView(spacer, slp);
                }
            }
        }
        if (firstCard != null) {
            a.tvInitialFocus = firstCard;
        }
    }

    private View buildPosterCard(
            final LocalMediaLibrary.LocalVideoItem item, int posterW, int posterH) {
        LinearLayout card = a.vertical();
        card.setTag("local-card:" + item.id);
        card.setFocusable(true);
        card.setFocusableInTouchMode(true);
        card.setClickable(true);
        card.setClipChildren(false);
        card.setClipToPadding(false);
        UiCompat.setDefaultFocusHighlightEnabled(card, false);

        final FrameLayout artFrame = new FrameLayout(a);
        ImageView poster = new ImageView(a);
        TvV17PosterCard.artwork(a, poster);
        if (!item.posterUrl.isEmpty()) {
            ImageLoader.poster(a, item.posterUrl, poster, false);
        }
        posterViewsById.put(item.id, poster);
        artFrame.addView(poster, new FrameLayout.LayoutParams(-1, -1));

        // Subtle bottom scrim inside poster for remarks readability
        View scrim = new View(a);
        scrim.setBackground(
                new GradientDrawable(
                        GradientDrawable.Orientation.BOTTOM_TOP,
                        new int[] {0xd8080b10, 0x44080b10, 0x00080b10}));
        artFrame.addView(scrim, new FrameLayout.LayoutParams(-1, a.dp(56), Gravity.BOTTOM));

        // Top-right Douban rating badge (populated immediately or when scraper finishes)
        TextView ratingBadge =
                a.text(
                        item.doubanScore > 0.1
                                ? String.format(Locale.US, "豆 %.1f", item.doubanScore)
                                : "",
                        10.5f,
                        0xfffbbf24);
        ratingBadge.setTypeface(null, Typeface.BOLD);
        ratingBadge.setPadding(a.dp(6), a.dp(2), a.dp(6), a.dp(2));
        ratingBadge.setBackground(TvV17Surface.rounded(0xcc12161e, a.dp(6), 0x44fbbf24, 1));
        ratingBadge.setVisibility(item.doubanScore > 0.1 ? View.VISIBLE : View.GONE);
        FrameLayout.LayoutParams ratLp =
                new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.END);
        ratLp.topMargin = a.dp(7);
        ratLp.rightMargin = a.dp(7);
        artFrame.addView(ratingBadge, ratLp);
        badgeViewsById.put(item.id, ratingBadge);

        // Top-left type pill (剧集 / 电影)
        TextView kindBadge = a.text(item.isSeries ? "剧集" : "电影", 10f, Color.WHITE);
        kindBadge.setTypeface(null, Typeface.BOLD);
        kindBadge.setPadding(a.dp(6), a.dp(2), a.dp(6), a.dp(2));
        kindBadge.setBackground(
                TvV17Surface.rounded(item.isSeries ? 0xcc4f46e5 : 0xcc0284c7, a.dp(6), 0, 0));
        FrameLayout.LayoutParams kindLp =
                new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.START);
        kindLp.topMargin = a.dp(7);
        kindLp.leftMargin = a.dp(7);
        artFrame.addView(kindBadge, kindLp);

        // Bottom-left remarks (4K · 共 24 集 / size)
        if (!item.remarks.isEmpty()) {
            TextView rem = a.text(item.remarks, 11f, 0xe8f5f5f7);
            rem.setSingleLine(true);
            rem.setEllipsize(TextUtils.TruncateAt.END);
            rem.setPadding(a.dp(8), a.dp(3), a.dp(8), a.dp(6));
            artFrame.addView(rem, new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM));
        }

        card.addView(artFrame, new LinearLayout.LayoutParams(-1, posterH));

        TextView titleTv = a.text(item.title, 13.5f, TvV17Theme.TEXT);
        titleTv.setTypeface(null, Typeface.BOLD);
        titleTv.setSingleLine(true);
        titleTv.setEllipsize(TextUtils.TruncateAt.END);
        titleTv.setPadding(a.dp(2), a.dp(8), a.dp(2), 0);
        card.addView(titleTv);

        String meta =
                (!item.year.isEmpty() ? item.year + " · " : "")
                        + (item.driveLabel.isEmpty() ? "移动硬盘" : item.driveLabel);
        TextView metaTv = a.text(meta, 11f, 0x99ebebf5);
        metaTv.setSingleLine(true);
        metaTv.setEllipsize(TextUtils.TruncateAt.END);
        metaTv.setPadding(a.dp(2), a.dp(2), a.dp(2), 0);
        card.addView(metaTv);

        card.setOnFocusChangeListener(
                (v, focused) -> TvV17PosterCard.focus(a, card, titleTv, focused));
        card.setOnClickListener(
                v -> {
                    Cms.Site site = LocalMediaLibrary.localSite(item.driveLabel);
                    Cms.Video video = item.toCmsVideo();
                    a.open(
                            new MainActivity.Screen(() -> TvDetailHost.show(a, site, video, video)),
                            true);
                });
        return card;
    }

    private void openDirectoryPicker() {
        try {
            Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
            intent.addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                            | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
            a.startActivityForResult(intent, LocalDriveScanner.REQ_LOCAL_DRIVE_TREE);
        } catch (Throwable err) {
            a.toast("当前电视系统不支持文件夹选择器，请直接开启「全部文件访问权限」后自动扫描硬盘");
            a.openTvStoragePermissionSettings();
        }
    }

    static void onTreeSelected(MainActivity a, Intent data) {
        if (a == null || data == null || data.getData() == null) return;
        Uri treeUri = data.getData();
        try {
            int flags =
                    data.getFlags()
                            & (Intent.FLAG_GRANT_READ_URI_PERMISSION
                                    | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
            if (Build.VERSION.SDK_INT >= 19) {
                a.getContentResolver()
                        .takePersistableUriPermission(
                                treeUri,
                                flags == 0 ? Intent.FLAG_GRANT_READ_URI_PERMISSION : flags);
            }
        } catch (Throwable ignored) {
        }
        LocalDriveScanner.addPersistedTreeUri(a, treeUri.toString());
        a.toast("已添加硬盘目录，正在重新扫描…");
        a.open(new MainActivity.Screen(() -> new TvLocalDriveScreen(a).show()), false);
    }
}
