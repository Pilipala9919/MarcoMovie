package com.pilipala.marcomovie;

import android.graphics.Color;
import android.graphics.Typeface;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.List;
import java.util.Locale;

/**
 * Redesigned Mobile Library Page ({@code 片库}):
 * - 4-way segmented bar: {@code 观看历史 · 我的收藏 · 追剧日历 · 离线下载}
 * - Top-right 1-tap {@code ☁ 云同步} status capsule (WebDAV & LAN sync)
 * - {@code 追剧日历} integrates Bangumi daily broadcast schedule + personal Bangumi/Trakt watching
 *   lists via {@link TrackingRatingService}.
 */
final class MobileLibraryPage {
    private static int selectedWeekday = 0;

    private MobileLibraryPage() {}

    static void render(final MobileRootShell shell, final FrameLayout container) {
        final MainActivity a = shell.a;
        if (selectedWeekday <= 0) selectedWeekday = TrackingRatingService.todayWeekday();

        LinearLayout page = a.vertical();
        page.setPadding(a.dp(16), a.statusBarHeight() + a.dp(10), a.dp(16), 0);
        container.addView(page, new FrameLayout.LayoutParams(-1, -1));

        // 1. Header Row: Title + Cloud Sync Pill
        LinearLayout topRow = a.row();
        topRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView title = a.text("我的片库", 22, Color.WHITE);
        title.setTypeface(null, Typeface.BOLD);
        topRow.addView(title, new LinearLayout.LayoutParams(0, -2, 1f));

        final TextView syncPill = a.text("☁ 云同步", 12f, a.mobileAccentColor());
        syncPill.setTypeface(null, Typeface.BOLD);
        syncPill.setPadding(a.dp(12), a.dp(6), a.dp(12), a.dp(6));
        syncPill.setBackground(
                UiWidgets.glassBg(0xc41a2421, 0xc4121816, a.dp(999), a.dp(0.8f), 0x38ffffff));
        UiWidgets.bindTouchFeedback(syncPill);
        topRow.addView(syncPill);
        page.addView(topRow, new LinearLayout.LayoutParams(-1, -2));
        a.gap(page, 10);

        // 2. 4-Way Segmented Sub-Tab Row
        HorizontalScrollView segHsv = new HorizontalScrollView(a);
        segHsv.setHorizontalScrollBarEnabled(false);
        LinearLayout segRow = a.row();
        segHsv.addView(segRow);

        final String[] subNames = {"观看历史", "我的收藏", "追剧日历", "离线下载"};
        final TextView[] subBtns = new TextView[4];
        for (int i = 0; i < 4; i++) {
            TextView tv = a.text(subNames[i], 13f, MainActivity.MUTED);
            if (i == 3) tv.setTag("my-downloads");
            subBtns[i] = tv;
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
            lp.rightMargin = a.dp(8);
            segRow.addView(tv, lp);
        }
        page.addView(segHsv, new LinearLayout.LayoutParams(-1, -2));
        a.gap(page, 10);

        ScrollView sv = new ScrollView(a);
        sv.setVerticalScrollBarEnabled(false);
        sv.setFillViewport(true);
        shell.bindScrollBehavior(sv);
        final LinearLayout listBody = a.vertical();
        listBody.setPadding(0, a.dp(2), 0, a.dp(108));
        sv.addView(listBody, new ScrollView.LayoutParams(-1, -2));
        page.addView(sv, new LinearLayout.LayoutParams(-1, 0, 1f));

        final Runnable refreshSubTab =
                new Runnable() {
                    @Override
                    public void run() {
                        int cur = MobileRootShell.librarySubTab;
                        int accent = a.mobileAccentColor();
                        for (int i = 0; i < 4; i++) {
                            boolean active = (i == cur);
                            TextView b = subBtns[i];
                            b.setTextColor(active ? 0xff08120e : 0xffe5e7eb);
                            b.setTypeface(null, active ? Typeface.BOLD : Typeface.NORMAL);
                            b.setPadding(a.dp(14), a.dp(7), a.dp(14), a.dp(7));
                            b.setBackground(
                                    active
                                            ? a.bg(accent, 999)
                                            : UiWidgets.glassBg(
                                                    0xb81c2421,
                                                    0xb8141a18,
                                                    a.dp(999),
                                                    a.dp(0.7f),
                                                    0x26ffffff));
                        }
                        listBody.removeAllViews();
                        if (cur == 0) {
                            renderHistoryList(a, listBody, this);
                        } else if (cur == 1) {
                            renderFavoritesList(a, listBody, this);
                        } else if (cur == 2) {
                            renderFollowCalendar(a, listBody);
                        } else {
                            MobileDownloads.render(a, listBody);
                        }
                    }
                };

        for (int i = 0; i < 4; i++) {
            final int idx = i;
            UiWidgets.bindTouchFeedback(subBtns[i]);
            subBtns[i].setOnClickListener(
                    v -> {
                        MobileRootShell.librarySubTab = idx;
                        refreshSubTab.run();
                    });
        }
        syncPill.setOnClickListener(v -> CloudSyncDialog.show(a, refreshSubTab));

        refreshSubTab.run();
    }

    private static void renderHistoryList(
            final MainActivity a, LinearLayout parent, final Runnable reload) {
        List<WatchHistory.Entry> items = a.watchHistory();
        if (items.isEmpty()) {
            TextView empty = a.text("暂无观看历史记录", 13.5f, MainActivity.MUTED);
            empty.setGravity(Gravity.CENTER);
            empty.setPadding(0, a.dp(48), 0, a.dp(48));
            parent.addView(empty, new LinearLayout.LayoutParams(-1, -2));
            return;
        }
        LinearLayout bar = a.row();
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(a.dp(2), 0, a.dp(2), a.dp(8));
        bar.addView(
                a.text("共 " + items.size() + " 条记录 · 点击续播", 12f, MainActivity.MUTED),
                new LinearLayout.LayoutParams(0, -2, 1f));
        TextView clearAll = a.text("清空全部", 12f, 0xffef4444);
        UiWidgets.bindTouchFeedback(clearAll);
        clearAll.setOnClickListener(
                v ->
                        new AppDialog.Builder(a)
                                .setTitle("清空观看历史？")
                                .setMessage("此操作将移除本机全部观看进度记录。")
                                .setNegativeButton("取消", null)
                                .setPositiveButton(
                                        "清空",
                                        (d, w) -> {
                                            a.prefs
                                                    .edit()
                                                    .putString(Prefs.WATCH_HISTORY, "[]")
                                                    .apply();
                                            reload.run();
                                        })
                                .show());
        bar.addView(clearAll);
        parent.addView(bar);

        for (final WatchHistory.Entry e : items) {
            LinearLayout row = a.row();
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(a.dp(10), a.dp(10), a.dp(12), a.dp(10));
            row.setBackground(
                    UiWidgets.glassBg(0xc01b2320, 0xc0131917, a.dp(16), a.dp(0.7f), 0x26ffffff));
            UiWidgets.bindTouchFeedback(row);
            row.setOnClickListener(v -> a.resumeHistory(e));

            ImageView pic = new ImageView(a);
            pic.setScaleType(ImageView.ScaleType.CENTER_CROP);
            pic.setBackground(a.bg(0xff232b28, 10));
            pic.setClipToOutline(true);
            if (e.poster != null && !e.poster.isEmpty()) a.poster(e.poster, pic);
            LinearLayout.LayoutParams pLp = new LinearLayout.LayoutParams(a.dp(52), a.dp(74));
            pLp.rightMargin = a.dp(12);
            row.addView(pic, pLp);

            LinearLayout info = a.vertical();
            TextView t = a.text(e.title, 14.5f, Color.WHITE);
            t.setTypeface(null, Typeface.BOLD);
            t.setSingleLine(true);
            t.setEllipsize(TextUtils.TruncateAt.END);
            info.addView(t);

            TextView sub = a.text(a.historyLabel(e), 12f, MainActivity.MUTED);
            sub.setPadding(0, a.dp(4), 0, 0);
            info.addView(sub);
            row.addView(info, new LinearLayout.LayoutParams(0, -2, 1f));

            TextView del = a.text("删除", 12f, 0xffef4444);
            del.setPadding(a.dp(10), a.dp(6), a.dp(6), a.dp(6));
            UiWidgets.bindTouchFeedback(del);
            del.setOnClickListener(
                    v -> {
                        a.prefs
                                .edit()
                                .putString(
                                        Prefs.WATCH_HISTORY,
                                        WatchHistory.remove(
                                                a.prefs.getString(Prefs.WATCH_HISTORY, "[]"),
                                                e.key()))
                                .apply();
                        reload.run();
                    });
            row.addView(del);

            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
            lp.bottomMargin = a.dp(9);
            parent.addView(row, lp);
        }
    }

    private static void renderFavoritesList(
            final MainActivity a, LinearLayout parent, final Runnable reload) {
        List<Favorites.Entry> favs = Favorites.read(a.prefs.getString(Prefs.FAVORITES, "[]"));
        if (favs.isEmpty()) {
            TextView empty = a.text("暂无收藏影片，可在影片详情页点击「收藏」添加", 13.5f, MainActivity.MUTED);
            empty.setGravity(Gravity.CENTER);
            empty.setPadding(0, a.dp(48), 0, a.dp(48));
            parent.addView(empty, new LinearLayout.LayoutParams(-1, -2));
            return;
        }
        for (final Favorites.Entry f : favs) {
            LinearLayout row = a.row();
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(a.dp(10), a.dp(10), a.dp(12), a.dp(10));
            row.setBackground(
                    UiWidgets.glassBg(0xc01b2320, 0xc0131917, a.dp(16), a.dp(0.7f), 0x26ffffff));
            UiWidgets.bindTouchFeedback(row);
            row.setOnClickListener(
                    v -> {
                        Cms.Site targetSite = null;
                        if (a.config != null) {
                            for (Cms.Site s : a.config.sites) {
                                if (s.key.equals(f.site)) {
                                    targetSite = s;
                                    break;
                                }
                            }
                        }
                        if (targetSite == null) {
                            MobileRootShell.openSearch(a, f.title);
                            return;
                        }
                        final Cms.Site resolvedSite = targetSite;
                        final Cms.Video vid = f.video();
                        a.open(new MainActivity.Screen(() -> a.detail(resolvedSite, vid)), true);
                    });

            ImageView pic = new ImageView(a);
            pic.setScaleType(ImageView.ScaleType.CENTER_CROP);
            pic.setBackground(a.bg(0xff232b28, 10));
            pic.setClipToOutline(true);
            if (f.poster != null && !f.poster.isEmpty()) a.poster(f.poster, pic);
            LinearLayout.LayoutParams pLp = new LinearLayout.LayoutParams(a.dp(52), a.dp(74));
            pLp.rightMargin = a.dp(12);
            row.addView(pic, pLp);

            LinearLayout info = a.vertical();
            TextView t = a.text(f.title, 14.5f, Color.WHITE);
            t.setTypeface(null, Typeface.BOLD);
            t.setSingleLine(true);
            t.setEllipsize(TextUtils.TruncateAt.END);
            info.addView(t);

            String siteDisplay = f.site;
            if (a.config != null) {
                for (Cms.Site s : a.config.sites) {
                    if (s.key.equals(f.site)) {
                        siteDisplay = s.name;
                        break;
                    }
                }
            }
            TextView sub = a.text("来源：" + siteDisplay, 12f, MainActivity.MUTED);
            sub.setPadding(0, a.dp(4), 0, 0);
            info.addView(sub);
            row.addView(info, new LinearLayout.LayoutParams(0, -2, 1f));

            TextView del = a.text("取消收藏", 12f, 0xffef4444);
            del.setPadding(a.dp(8), a.dp(6), a.dp(6), a.dp(6));
            UiWidgets.bindTouchFeedback(del);
            del.setOnClickListener(
                    v -> {
                        a.prefs
                                .edit()
                                .putString(
                                        Prefs.FAVORITES,
                                        Favorites.toggle(
                                                a.prefs.getString(Prefs.FAVORITES, "[]"),
                                                f.site,
                                                f.video()))
                                .apply();
                        reload.run();
                    });
            row.addView(del);

            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
            lp.bottomMargin = a.dp(9);
            parent.addView(row, lp);
        }
    }

    private static void renderFollowCalendar(final MainActivity a, final LinearLayout parent) {
        final String[] dayLabels = {"周一", "周二", "周三", "周四", "周五", "周六", "周日"};
        HorizontalScrollView dayHsv = new HorizontalScrollView(a);
        dayHsv.setHorizontalScrollBarEnabled(false);
        final LinearLayout dayRow = a.row();
        dayHsv.addView(dayRow);
        parent.addView(dayHsv, new LinearLayout.LayoutParams(-1, -2));
        a.gap(parent, 10);

        final LinearLayout itemsBox = a.vertical();
        parent.addView(itemsBox, new LinearLayout.LayoutParams(-1, -2));
        itemsBox.addView(a.text("正在同步每日放送与 Trakt / Bangumi 追剧日历…", 13f, MainActivity.MUTED));

        TrackingRatingService.fetchFollowCalendarAsync(
                a,
                entries -> {
                    final Runnable renderDay =
                            new Runnable() {
                                @Override
                                public void run() {
                                    dayRow.removeAllViews();
                                    int accent = a.mobileAccentColor();
                                    for (int d = 1; d <= 7; d++) {
                                        final int dayNum = d;
                                        boolean sel = (d == selectedWeekday);
                                        TextView pill =
                                                a.text(
                                                        dayLabels[d - 1],
                                                        12f,
                                                        sel ? 0xff08120e : 0xffd1d5db);
                                        pill.setTypeface(
                                                null, sel ? Typeface.BOLD : Typeface.NORMAL);
                                        pill.setPadding(a.dp(12), a.dp(5), a.dp(12), a.dp(5));
                                        pill.setBackground(
                                                sel ? a.bg(accent, 999) : a.bg(0xff1b2320, 999));
                                        UiWidgets.bindTouchFeedback(pill);
                                        pill.setOnClickListener(
                                                v -> {
                                                    selectedWeekday = dayNum;
                                                    run();
                                                });
                                        LinearLayout.LayoutParams lp =
                                                new LinearLayout.LayoutParams(-2, -2);
                                        lp.rightMargin = a.dp(7);
                                        dayRow.addView(pill, lp);
                                    }

                                    itemsBox.removeAllViews();
                                    if (entries == null || entries.isEmpty()) {
                                        itemsBox.addView(
                                                a.text(
                                                        "未能加载追剧日历，请检查网络连接或在设置中配置 Bangumi / Trakt 账号。",
                                                        13f,
                                                        MainActivity.MUTED));
                                        return;
                                    }
                                    int shown = 0;
                                    for (final TrackingRatingService.CalendarEntry ce : entries) {
                                        if (ce.weekday != selectedWeekday) continue;
                                        shown++;
                                        LinearLayout card = a.row();
                                        card.setGravity(Gravity.CENTER_VERTICAL);
                                        card.setPadding(a.dp(10), a.dp(10), a.dp(12), a.dp(10));
                                        card.setBackground(
                                                UiWidgets.glassBg(
                                                        0xc01b2320,
                                                        0xc0131917,
                                                        a.dp(16),
                                                        a.dp(0.7f),
                                                        0x26ffffff));
                                        UiWidgets.bindTouchFeedback(card);
                                        card.setOnClickListener(
                                                v -> MobileRootShell.openSearch(a, ce.title));

                                        ImageView pic = new ImageView(a);
                                        pic.setScaleType(ImageView.ScaleType.CENTER_CROP);
                                        pic.setBackground(a.bg(0xff232b28, 10));
                                        pic.setClipToOutline(true);
                                        if (ce.posterUrl != null && !ce.posterUrl.isEmpty()) {
                                            a.poster(ce.posterUrl, pic);
                                        }
                                        LinearLayout.LayoutParams pLp =
                                                new LinearLayout.LayoutParams(a.dp(50), a.dp(70));
                                        pLp.rightMargin = a.dp(12);
                                        card.addView(pic, pLp);

                                        LinearLayout info = a.vertical();
                                        TextView t = a.text(ce.title, 14.5f, Color.WHITE);
                                        t.setTypeface(null, Typeface.BOLD);
                                        t.setSingleLine(true);
                                        t.setEllipsize(TextUtils.TruncateAt.END);
                                        info.addView(t);

                                        String meta =
                                                ce.sourceBadge
                                                        + (ce.subtitle.isEmpty()
                                                                ? ""
                                                                : (" · " + ce.subtitle))
                                                        + (ce.rating > 0
                                                                ? String.format(
                                                                        Locale.US,
                                                                        " · ★ %.1f",
                                                                        ce.rating)
                                                                : "");
                                        TextView sub = a.text(meta, 12f, a.mobileAccentColor());
                                        sub.setPadding(0, a.dp(4), 0, 0);
                                        info.addView(sub);
                                        card.addView(
                                                info, new LinearLayout.LayoutParams(0, -2, 1f));

                                        TextView searchTag =
                                                a.text("搜源 ›", 12f, MainActivity.MUTED);
                                        card.addView(searchTag);

                                        LinearLayout.LayoutParams lp =
                                                new LinearLayout.LayoutParams(-1, -2);
                                        lp.bottomMargin = a.dp(9);
                                        itemsBox.addView(card, lp);
                                    }
                                    if (shown == 0) {
                                        itemsBox.addView(
                                                a.text("当日暂无更新番剧记录", 13f, MainActivity.MUTED));
                                    }
                                }
                            };
                    renderDay.run();
                });
    }
}
