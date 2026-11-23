package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/**
 * Apple tvOS-inspired "Mine" hub featuring a frosted profile & live workspace status hero, a
 * vector-icon glass quick-action tile dock, a cinematic 16:9 Continue-Watching rail with playback
 * progress indicators, and a full Favorites poster rail.
 */
final class TvV17MineScreen {
    private static final int MAX_HISTORY_SHELF = 6;
    private static final int MAX_FAVORITES_SHELF = 8;

    private static final int ICON_HISTORY = 0;
    private static final int ICON_FAVORITE = 1;
    private static final int ICON_CLOUD = 2;
    private static final int ICON_CAST = 3;
    private static final int ICON_GATEWAY = 4;
    private static final int ICON_SYNC = 5;
    private static final int ICON_PRIVACY = 6;
    private static final int ICON_SETTINGS = 7;

    private final MainActivity a;

    TvV17MineScreen(MainActivity activity) {
        a = activity;
    }

    void show() {
        a.renderPage("", "");
        if (a.body != null) {
            a.body.setPadding(a.dp(48), a.dp(24), a.dp(48), a.dp(44));
        }

        List<WatchHistory.Entry> history = a.watchHistory();
        boolean historyCorrupted =
                WatchHistory.isCorrupted()
                        || a.prefs.getBoolean(WatchHistory.CORRUPTED_PREF, false);
        List<Favorites.Entry> favorites = Favorites.read(a.prefs.getString(Prefs.FAVORITES, "[]"));
        int sitesCount = a.config != null && a.config.sites != null ? a.config.sites.size() : 0;

        renderHeaderBar();
        a.gap(a.body, 16);
        renderProfileHero(history.size(), favorites.size(), sitesCount);
        a.gap(a.body, 18);
        renderQuickActionTiles(history.size(), favorites.size());
        a.gap(a.body, 26);
        renderContinueWatchingShelf(history, historyCorrupted);
        a.gap(a.body, 26);
        renderFavoritesShelf(favorites);
    }

    private void renderHeaderBar() {
        LinearLayout header = a.row();
        header.setGravity(Gravity.CENTER_VERTICAL);

        TextView heading = a.text("我的", 30, TvV17Theme.TEXT);
        heading.setTypeface(null, Typeface.BOLD);
        header.addView(heading, new LinearLayout.LayoutParams(-2, -2));

        TextView spacePill =
                a.text(
                        a.privateMode ? "● 隐私空间已锁定" : "个人影音中心",
                        12,
                        a.privateMode ? 0xfffbbf24 : 0xccebebf5);
        spacePill.setTypeface(null, Typeface.BOLD);
        spacePill.setPadding(a.dp(12), a.dp(5), a.dp(12), a.dp(5));
        spacePill.setBackground(
                TvV17Surface.rounded(
                        a.privateMode ? 0x26fbbf24 : 0x22ffffff,
                        a.dp(999),
                        a.privateMode ? 0x44fbbf24 : 0x26ffffff,
                        a.dp(1)));
        LinearLayout.LayoutParams pillLp = new LinearLayout.LayoutParams(-2, -2);
        pillLp.leftMargin = a.dp(14);
        header.addView(spacePill, pillLp);

        header.addView(new View(a), new LinearLayout.LayoutParams(0, 1, 1f));

        String clockText = new SimpleDateFormat("HH:mm", Locale.getDefault()).format(new Date());
        TextView clock = a.text(clockText, 15.5f, 0xb8ebebf5);
        clock.setTypeface(null, Typeface.BOLD);
        header.addView(clock);
        a.body.addView(header, new LinearLayout.LayoutParams(-1, -2));
    }

    private void renderProfileHero(int historyCount, int favCount, int sitesCount) {
        LinearLayout hero = a.row();
        hero.setTag("mine-profile-hero");
        hero.setGravity(Gravity.CENTER_VERTICAL);
        hero.setPadding(a.dp(24), a.dp(18), a.dp(24), a.dp(18));
        hero.setBackground(glassSurface(a.privateMode ? 0x66221b14 : 0x5c141926, 20, 0x2affffff));
        UiCompat.setElevation(hero, a.dp(10));

        // Circular Brand Monogram Avatar
        FrameLayout avatar = new FrameLayout(a);
        GradientDrawable avatarBg = new GradientDrawable();
        avatarBg.setShape(GradientDrawable.OVAL);
        avatarBg.setColor(a.privateMode ? 0xff453218 : 0xff1e2d48);
        avatarBg.setStroke(a.dp(1.5f), a.privateMode ? 0x99fbbf24 : 0x667cb8ff);
        avatar.setBackground(avatarBg);
        TextView mono =
                a.text(a.privateMode ? "🔒" : "M", 22, a.privateMode ? 0xfffbbf24 : Color.WHITE);
        mono.setTypeface(null, Typeface.BOLD);
        mono.setGravity(Gravity.CENTER);
        avatar.addView(mono, new FrameLayout.LayoutParams(-1, -1));
        LinearLayout.LayoutParams avLp = new LinearLayout.LayoutParams(a.dp(54), a.dp(54));
        avLp.rightMargin = a.dp(18);
        hero.addView(avatar, avLp);

        // Workspace title + live dynamic summary
        LinearLayout info = a.vertical();
        TextView title =
                a.text(a.privateMode ? "隐私空间 · 独立数据隔离" : "Marco Movie · 客厅影院", 19, TvV17Theme.TEXT);
        title.setTypeface(null, Typeface.BOLD);
        info.addView(title);

        String subtitle = buildWorkspaceSubtitle(sitesCount);
        TextView sub = a.text(subtitle, 13, 0xa8ebebf5);
        sub.setSingleLine(true);
        sub.setEllipsize(TextUtils.TruncateAt.END);
        sub.setPadding(0, a.dp(5), 0, 0);
        info.addView(sub);
        hero.addView(info, new LinearLayout.LayoutParams(0, -2, 1f));

        // 3 compact stat chips
        LinearLayout stats = a.row();
        stats.setGravity(Gravity.CENTER_VERTICAL);
        addHeroStat(stats, String.valueOf(historyCount), "观看历史", 0xff7cb8ff);
        addHeroStat(stats, String.valueOf(favCount), "我的收藏", 0xfffbbf24);
        addHeroStat(stats, String.valueOf(sitesCount), "可用片源", 0xff66d4cf);
        hero.addView(stats, new LinearLayout.LayoutParams(-2, -2));

        a.body.addView(hero, new LinearLayout.LayoutParams(-1, -2));
    }

    private String buildWorkspaceSubtitle(int sitesCount) {
        StringBuilder sb = new StringBuilder();
        if (a.config != null
                && a.config.warehouse != null
                && !a.config.warehouse.trim().isEmpty()) {
            sb.append("订阅：").append(a.config.warehouse.trim());
        } else if (sitesCount > 0) {
            sb.append("已配置 ").append(sitesCount).append(" 条片源线路");
        } else {
            sb.append("暂未导入影视订阅源");
        }
        boolean castOn = a.castService != null && !a.castService.closed;
        boolean gwOn = a.spiderGateway != null && !a.spiderGateway.closed;
        sb.append("  ·  ").append(castOn ? "投屏接收已就绪" : "投屏已关闭");
        if (!a.privateMode && gwOn) {
            sb.append("  ·  蜘蛛网关运行中");
        }
        return sb.toString();
    }

    private void addHeroStat(LinearLayout parent, String value, String label, int accentColor) {
        LinearLayout box = a.vertical();
        box.setGravity(Gravity.CENTER);
        box.setPadding(a.dp(16), a.dp(8), a.dp(16), a.dp(8));
        box.setBackground(TvV17Surface.rounded(0x18ffffff, a.dp(14), 0x1effffff, a.dp(1)));

        TextView v = a.text(value, 18, accentColor);
        v.setTypeface(null, Typeface.BOLD);
        box.addView(v);

        TextView l = a.text(label, 11, 0x99ebebf5);
        l.setPadding(0, a.dp(2), 0, 0);
        box.addView(l);

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(a.dp(84), -2);
        lp.leftMargin = a.dp(10);
        parent.addView(box, lp);
    }

    private void renderQuickActionTiles(int historyCount, int favCount) {
        HorizontalScrollView viewport = new HorizontalScrollView(a);
        viewport.setTag("mine-actions-viewport");
        viewport.setFocusable(false);
        viewport.setFillViewport(true);
        viewport.setHorizontalScrollBarEnabled(false);
        viewport.setClipChildren(false);
        viewport.setClipToPadding(false);
        viewport.setPadding(a.dp(2), a.dp(6), a.dp(2), a.dp(8));

        LinearLayout row = a.row();
        row.setTag("mine-actions");
        row.setClipChildren(false);
        row.setClipToPadding(false);

        boolean castOn = a.prefs.getBoolean(Prefs.CAST_ENABLED, true);
        boolean gwOn = !a.privateMode && a.prefs.getBoolean(Prefs.SPIDER_GATEWAY_ENABLED, false);

        final View[] tiles = {
            buildActionTile(
                    ICON_HISTORY,
                    0xff60a5fa,
                    "观看历史",
                    historyCount > 0 ? historyCount + " 条记录" : "暂无记录",
                    "mine-history",
                    this::openHistory),
            buildActionTile(
                    ICON_FAVORITE,
                    0xfffbbf24,
                    "我的收藏",
                    favCount > 0 ? favCount + " 部片单" : "暂无收藏",
                    "mine-favorites",
                    this::openFavorites),
            buildActionTile(
                    ICON_CLOUD,
                    0xff34d399,
                    "网盘与账号",
                    "扫码登录",
                    "mine-accounts",
                    () -> AccountPanel.show(a, null)),
            buildActionTile(
                    ICON_CAST,
                    0xff38bdf8,
                    "无线投屏",
                    castOn ? "接收就绪" : "已关闭",
                    "mine-cast",
                    () -> a.open(new MainActivity.Screen(a::castScreen), true)),
            buildActionTile(
                    ICON_GATEWAY,
                    0xffa78bfa,
                    "蜘蛛网关",
                    gwOn ? "运行中" : "iOS 伴侣",
                    "mine-spider-gateway",
                    () -> SpiderGatewayDialog.show(a)),
            buildActionTile(
                    ICON_SYNC,
                    0xff2dd4bf,
                    "多端同步",
                    "云端/局域网",
                    "mine-sync",
                    () -> CloudSyncDialog.show(a, null)),
            buildActionTile(
                    ICON_PRIVACY,
                    0xfff472b6,
                    a.privateMode ? "退出隐私" : "隐私空间",
                    a.privateMode ? "已锁定" : "独立加密",
                    "mine-private",
                    () -> PrivacySpace.openTv(a)),
            buildActionTile(
                    ICON_SETTINGS,
                    0xffcbd5e1,
                    "系统设置",
                    "外观与播放",
                    "mine-settings",
                    () -> a.open(new MainActivity.Screen(a::settings), true))
        };

        final int minimum = a.dp(106);
        final int gap = a.dp(10);
        final int height = a.dp(88);
        for (int i = 0; i < tiles.length; i++) {
            final View tile = tiles[i];
            tile.setId(View.generateViewId());
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(minimum, height);
            if (i + 1 < tiles.length) lp.rightMargin = gap;
            row.addView(tile, lp);
        }
        for (int i = 0; i < tiles.length; i++) {
            final View tile = tiles[i];
            if (i > 0) tile.setNextFocusLeftId(tiles[i - 1].getId());
            if (i + 1 < tiles.length) tile.setNextFocusRightId(tiles[i + 1].getId());
            final View.OnFocusChangeListener prev = tile.getOnFocusChangeListener();
            tile.setOnFocusChangeListener(
                    (v, focused) -> {
                        if (prev != null) prev.onFocusChange(v, focused);
                        if (focused) {
                            viewport.post(
                                    () -> {
                                        if (!tile.hasFocus() || !viewport.isAttachedToWindow()) {
                                            return;
                                        }
                                        Rect rect =
                                                new Rect(
                                                        tile.getLeft() - a.dp(6),
                                                        0,
                                                        tile.getRight() + a.dp(6),
                                                        row.getHeight());
                                        viewport.requestChildRectangleOnScreen(row, rect, true);
                                    });
                        }
                    });
        }

        viewport.addView(row, new HorizontalScrollView.LayoutParams(-2, -2));
        viewport.addOnLayoutChangeListener(
                (v, l, t, r, b, ol, ot, or, ob) -> {
                    int available = r - l - viewport.getPaddingLeft() - viewport.getPaddingRight();
                    int width = TvMineActionMetrics.width(available, minimum, gap, tiles.length);
                    for (View tile : tiles) {
                        LinearLayout.LayoutParams size =
                                (LinearLayout.LayoutParams) tile.getLayoutParams();
                        if (size.width != width) {
                            size.width = width;
                            tile.setLayoutParams(size);
                        }
                    }
                });
        a.body.addView(viewport, new LinearLayout.LayoutParams(-1, -2));
    }

    private LinearLayout buildActionTile(
            int iconKind,
            final int accentColor,
            String title,
            String subtitle,
            String tag,
            Runnable onClick) {
        LinearLayout tile = a.vertical();
        tile.setTag(tag);
        tile.setGravity(Gravity.CENTER);
        tile.setFocusable(true);
        tile.setFocusableInTouchMode(true);
        tile.setClickable(true);
        UiCompat.setDefaultFocusHighlightEnabled(tile, false);
        tile.setPadding(a.dp(10), a.dp(12), a.dp(10), a.dp(10));
        tile.setBackground(glassSurface(0x52151a26, 16, 0x22ffffff));

        final MineGlyph glyph = new MineGlyph(a, iconKind, accentColor);
        tile.addView(glyph, new LinearLayout.LayoutParams(a.dp(24), a.dp(24)));

        final TextView titleTv = a.text(title, 13.5f, TvV17Theme.TEXT);
        titleTv.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
        titleTv.setSingleLine(true);
        titleTv.setEllipsize(TextUtils.TruncateAt.END);
        titleTv.setGravity(Gravity.CENTER);
        titleTv.setPadding(0, a.dp(7), 0, 0);
        tile.addView(titleTv);

        final TextView subTv = a.text(subtitle, 10.5f, 0x99ebebf5);
        subTv.setSingleLine(true);
        subTv.setEllipsize(TextUtils.TruncateAt.END);
        subTv.setGravity(Gravity.CENTER);
        subTv.setPadding(0, a.dp(2), 0, 0);
        tile.addView(subTv);

        a.pressFeedback(tile);
        tile.setOnClickListener(v -> onClick.run());
        tile.setOnFocusChangeListener(
                (v, focused) -> {
                    FocusMotion.unclipAncestors(tile);
                    tile.setBackground(
                            focused
                                    ? TvV17Surface.rounded(
                                            0xf8ffffff, a.dp(16), 0xffffffff, a.dp(1))
                                    : glassSurface(0x52151a26, 16, 0x22ffffff));
                    glyph.setTint(focused ? 0xff0b0e14 : accentColor);
                    titleTv.setTextColor(focused ? 0xff0b0e14 : TvV17Theme.TEXT);
                    subTv.setTextColor(focused ? 0xff475569 : 0x99ebebf5);
                    UiCompat.setElevation(tile, focused ? a.dp(10) : 0);
                    tile.animate()
                            .scaleX(focused ? 1.05f : 1f)
                            .scaleY(focused ? 1.05f : 1f)
                            .setDuration(a.reduced ? 0 : 120)
                            .start();
                });
        return tile;
    }

    private void renderContinueWatchingShelf(
            List<WatchHistory.Entry> history, boolean historyCorrupted) {
        renderSectionHeader(
                "继续观看",
                history.isEmpty() ? "" : history.size() + " 部",
                "全部历史 ›",
                "mine-history-all",
                this::openHistory);
        a.gap(a.body, 10);

        if (historyCorrupted) {
            renderEmptyBanner("观看记录数据损坏，已保留本地备份并暂停更新。点击「全部历史」查看恢复选项。");
            return;
        }
        if (history.isEmpty()) {
            renderEmptyBanner("最近还没有观看记录 · 去首页挑一部喜欢的影片开始播放吧");
            return;
        }

        HorizontalScrollView scroll = new HorizontalScrollView(a);
        scroll.setFocusable(false);
        scroll.setHorizontalScrollBarEnabled(false);
        scroll.setClipChildren(false);
        scroll.setClipToPadding(false);
        scroll.setPadding(a.dp(2), a.dp(4), a.dp(2), a.dp(8));

        LinearLayout shelf = a.row();
        shelf.setClipChildren(false);
        shelf.setClipToPadding(false);
        int count = Math.min(MAX_HISTORY_SHELF, history.size());
        for (int i = 0; i < count; i++) {
            final WatchHistory.Entry entry = history.get(i);
            LinearLayout card = buildContinueCard(entry);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(a.dp(246), -2);
            if (i + 1 < count) lp.rightMargin = a.dp(16);
            shelf.addView(card, lp);
        }
        scroll.addView(shelf, new HorizontalScrollView.LayoutParams(-2, -2));
        a.body.addView(scroll, new LinearLayout.LayoutParams(-1, -2));
    }

    private LinearLayout buildContinueCard(final WatchHistory.Entry entry) {
        LinearLayout card = a.vertical();
        card.setTag("mine-history:" + entry.key());
        card.setFocusable(true);
        card.setFocusableInTouchMode(true);
        card.setClickable(true);
        UiCompat.setDefaultFocusHighlightEnabled(card, false);
        TvFocusFrame.attachCard(card, "mine-history");
        card.setPadding(a.dp(5), a.dp(5), a.dp(5), a.dp(8));

        FrameLayout frame = new FrameLayout(a);
        frame.setBackground(TvV17Surface.rounded(0xff181d28, a.dp(14), 0x22ffffff, a.dp(1)));
        if (android.os.Build.VERSION.SDK_INT >= 21) {
            frame.setClipToOutline(true);
            frame.setOutlineProvider(
                    new android.view.ViewOutlineProvider() {
                        @Override
                        public void getOutline(View view, android.graphics.Outline outline) {
                            outline.setRoundRect(0, 0, view.getWidth(), view.getHeight(), a.dp(14));
                        }
                    });
        }

        ImageView art = new ImageView(a);
        art.setScaleType(ImageView.ScaleType.CENTER_CROP);
        a.poster(entry.poster, art);
        frame.addView(art, new FrameLayout.LayoutParams(-1, -1));

        // Cinematic bottom gradient scrim
        View scrim = new View(a);
        GradientDrawable grad =
                new GradientDrawable(
                        GradientDrawable.Orientation.TOP_BOTTOM,
                        new int[] {0x00000000, 0x33000000, 0xcc090c12});
        scrim.setBackground(grad);
        frame.addView(scrim, new FrameLayout.LayoutParams(-1, a.dp(68), Gravity.BOTTOM));

        // Episode / progress pill badge
        float ratio = computeHistoryProgress(entry.position, entry.duration);
        String badgeText =
                entry.episode != null && !entry.episode.trim().isEmpty()
                        ? entry.episode.trim()
                        : (ratio > 0f ? "已看 " + Math.round(ratio * 100f) + "%" : "继续播放");
        if (badgeText.length() > 14) badgeText = badgeText.substring(0, 13) + "…";
        TextView badge = a.text(badgeText, 10.5f, 0xf2ffffff);
        badge.setTypeface(null, Typeface.BOLD);
        badge.setSingleLine(true);
        badge.setPadding(a.dp(8), a.dp(3), a.dp(8), a.dp(3));
        badge.setBackground(TvV17Surface.rounded(0xb810141c, a.dp(999), 0x30ffffff, a.dp(1)));
        FrameLayout.LayoutParams bLp =
                new FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM | Gravity.LEFT);
        bLp.leftMargin = a.dp(10);
        bLp.bottomMargin = a.dp(12);
        frame.addView(badge, bLp);

        // Playback progress bar along bottom edge
        if (ratio > 0f) {
            FrameLayout track = new FrameLayout(a);
            track.setBackground(TvV17Surface.rounded(0x40ffffff, a.dp(999), 0, 0));
            View fill = new View(a);
            fill.setBackground(TvV17Surface.rounded(0xf8ffffff, a.dp(999), 0, 0));
            int fillW = Math.max(a.dp(8), Math.round(a.dp(216) * ratio));
            track.addView(fill, new FrameLayout.LayoutParams(fillW, -1));
            FrameLayout.LayoutParams tLp =
                    new FrameLayout.LayoutParams(-1, a.dp(3.5f), Gravity.BOTTOM);
            tLp.leftMargin = a.dp(10);
            tLp.rightMargin = a.dp(10);
            tLp.bottomMargin = a.dp(5);
            frame.addView(track, tLp);
        }

        card.addView(frame, new LinearLayout.LayoutParams(-1, a.dp(134)));

        TextView name = a.text(entry.title == null ? "" : entry.title, 15, TvV17Theme.TEXT);
        name.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
        name.setSingleLine(true);
        name.setEllipsize(TextUtils.TruncateAt.END);
        name.setPadding(a.dp(4), a.dp(8), a.dp(4), 0);
        card.addView(name);

        TextView detail = a.text(CatalogScreen.historyLabel(entry), 11.5f, TvV17Theme.MUTED);
        detail.setSingleLine(true);
        detail.setEllipsize(TextUtils.TruncateAt.END);
        detail.setPadding(a.dp(4), a.dp(2), a.dp(4), 0);
        card.addView(detail);

        a.pressFeedback(card);
        card.setOnClickListener(v -> a.resumeHistory(entry));
        card.setOnLongClickListener(
                v -> {
                    openHistory();
                    return true;
                });
        TvMenuAction.bind(card, this::openHistory);
        card.setOnFocusChangeListener(
                (v, focused) -> TvV17PosterCard.focus(a, card, name, focused));
        return card;
    }

    private void renderFavoritesShelf(List<Favorites.Entry> favorites) {
        renderSectionHeader(
                "我的收藏",
                favorites.isEmpty() ? "" : favorites.size() + " 部",
                "全部收藏 ›",
                "mine-favorites-all",
                this::openFavorites);
        a.gap(a.body, 10);

        if (favorites.isEmpty()) {
            renderEmptyBanner("在影片详情页点击「收藏」即可把心仪影片收录到这里");
            return;
        }

        HorizontalScrollView scroll = new HorizontalScrollView(a);
        scroll.setFocusable(false);
        scroll.setHorizontalScrollBarEnabled(false);
        scroll.setClipChildren(false);
        scroll.setClipToPadding(false);
        scroll.setPadding(a.dp(2), a.dp(4), a.dp(2), a.dp(10));

        LinearLayout shelf = a.row();
        shelf.setClipChildren(false);
        shelf.setClipToPadding(false);
        FavoritesScreen handler = new FavoritesScreen(a);
        int count = Math.min(MAX_FAVORITES_SHELF, favorites.size());
        for (int i = 0; i < count; i++) {
            final Favorites.Entry entry = favorites.get(i);
            LinearLayout card = buildFavoriteCard(entry, handler);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(a.dp(146), -2);
            if (i + 1 < count) lp.rightMargin = a.dp(15);
            shelf.addView(card, lp);
        }
        scroll.addView(shelf, new HorizontalScrollView.LayoutParams(-2, -2));
        a.body.addView(scroll, new LinearLayout.LayoutParams(-1, -2));
    }

    private LinearLayout buildFavoriteCard(
            final Favorites.Entry entry, final FavoritesScreen handler) {
        LinearLayout card = a.vertical();
        card.setTag("mine-favorite:" + entry.key());
        card.setFocusable(true);
        card.setFocusableInTouchMode(true);
        card.setClickable(true);
        UiCompat.setDefaultFocusHighlightEnabled(card, false);
        TvFocusFrame.attachCard(card, "mine-favorites");
        card.setPadding(a.dp(5), a.dp(5), a.dp(5), a.dp(8));

        ImageView art = new ImageView(a);
        TvV17PosterCard.artwork(a, art);
        card.addView(art, new LinearLayout.LayoutParams(-1, a.dp(202)));
        a.poster(entry.poster, art);

        TextView name = a.text(entry.title == null ? "" : entry.title, 14.5f, TvV17Theme.TEXT);
        name.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
        name.setSingleLine(true);
        name.setEllipsize(TextUtils.TruncateAt.END);
        name.setPadding(a.dp(3), a.dp(7), a.dp(3), 0);
        card.addView(name);

        a.pressFeedback(card);
        card.setOnClickListener(v -> handler.open(entry));
        card.setOnLongClickListener(
                v -> {
                    handler.manage(entry);
                    return true;
                });
        TvMenuAction.bind(card, () -> handler.manage(entry));
        card.setOnFocusChangeListener(
                (v, focused) -> TvV17PosterCard.focus(a, card, name, focused));
        return card;
    }

    private void renderSectionHeader(
            String title,
            String countBadge,
            String actionLabel,
            String actionTag,
            Runnable action) {
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setClipChildren(false);

        TextView heading = a.text(title, 20, TvV17Theme.TEXT);
        heading.setTypeface(null, Typeface.BOLD);
        row.addView(heading);

        if (countBadge != null && !countBadge.isEmpty()) {
            TextView count = a.text(countBadge, 11.5f, 0xb8ebebf5);
            count.setPadding(a.dp(9), a.dp(3), a.dp(9), a.dp(3));
            count.setBackground(TvV17Surface.rounded(0x1cffffff, a.dp(999), 0, 0));
            LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(-2, -2);
            clp.leftMargin = a.dp(10);
            row.addView(count, clp);
        }

        row.addView(new View(a), new LinearLayout.LayoutParams(0, 1, 1f));

        TextView more = a.text(actionLabel, 12.5f, 0xccebebf5);
        more.setTag(actionTag);
        more.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
        more.setFocusable(true);
        more.setFocusableInTouchMode(true);
        more.setClickable(true);
        UiCompat.setDefaultFocusHighlightEnabled(more, false);
        more.setPadding(a.dp(12), a.dp(5), a.dp(12), a.dp(5));
        more.setBackground(TvV17Surface.rounded(0x1cffffff, a.dp(999), 0x22ffffff, a.dp(1)));
        a.pressFeedback(more);
        more.setOnClickListener(v -> action.run());
        more.setOnFocusChangeListener(
                (v, focused) -> {
                    FocusMotion.unclipAncestors(more);
                    more.setBackground(
                            TvV17Surface.rounded(
                                    focused ? 0xf8ffffff : 0x1cffffff,
                                    a.dp(999),
                                    focused ? 0xffffffff : 0x22ffffff,
                                    a.dp(1)));
                    more.setTextColor(focused ? 0xff0b0e14 : 0xccebebf5);
                    more.animate()
                            .scaleX(focused ? 1.05f : 1f)
                            .scaleY(focused ? 1.05f : 1f)
                            .setDuration(a.reduced ? 0 : 110)
                            .start();
                });
        row.addView(more);
        a.body.addView(row, new LinearLayout.LayoutParams(-1, -2));
    }

    private void renderEmptyBanner(String message) {
        TextView card = a.text(message, 14, 0x99ebebf5);
        card.setPadding(a.dp(20), a.dp(18), a.dp(20), a.dp(18));
        card.setBackground(glassSurface(0x44141925, 16, 0x1effffff));
        a.body.addView(card, new LinearLayout.LayoutParams(-1, -2));
    }

    private void openHistory() {
        a.open(new MainActivity.Screen(a::historyPage), true);
    }

    private void openFavorites() {
        a.open(new MainActivity.Screen(() -> new FavoritesScreen(a).show()), true);
    }

    private GradientDrawable glassSurface(int fill, float radiusDp, int stroke) {
        boolean reducedTrans =
                a.prefs != null && a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
        int bg = reducedTrans ? TvV17Theme.OPAQUE_SURFACE : fill;
        return TvV17Surface.rounded(bg, a.dp(radiusDp), stroke, a.dp(1));
    }

    /** Pure-JVM progress fraction helper for Continue Watching cards. */
    static float computeHistoryProgress(int positionMs, int durationMs) {
        if (durationMs <= 0 || positionMs <= 0) return 0f;
        float ratio = (float) positionMs / (float) durationMs;
        return Math.max(0.03f, Math.min(1f, ratio));
    }

    /** Crisp resolution-independent vector glyphs for Apple TV Mine quick-action tiles. */
    private static final class MineGlyph extends View {
        private final int kind;
        private final Paint stroke = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF box = new RectF();
        private final Path path = new Path();

        MineGlyph(Context ctx, int kind, int tint) {
            super(ctx);
            this.kind = kind;
            stroke.setStyle(Paint.Style.STROKE);
            stroke.setStrokeCap(Paint.Cap.ROUND);
            stroke.setStrokeJoin(Paint.Join.ROUND);
            fill.setStyle(Paint.Style.FILL);
            setTint(tint);
        }

        void setTint(int color) {
            stroke.setColor(color);
            fill.setColor(color);
            invalidate();
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth();
            int h = getHeight();
            if (w <= 0 || h <= 0) return;
            float s = Math.min(w, h);
            float cx = w * 0.5f;
            float cy = h * 0.5f;
            float r = s * 0.36f;
            stroke.setStrokeWidth(Math.max(2f, s * 0.085f));

            switch (kind) {
                case ICON_HISTORY:
                    canvas.drawCircle(cx, cy, r, stroke);
                    canvas.drawLine(cx, cy, cx, cy - r * 0.55f, stroke);
                    canvas.drawLine(cx, cy, cx + r * 0.48f, cy + r * 0.25f, stroke);
                    break;
                case ICON_FAVORITE:
                    path.reset();
                    for (int i = 0; i < 10; i++) {
                        double angle = Math.toRadians(-90 + i * 36);
                        float rad = (i % 2 == 0) ? r * 1.05f : r * 0.45f;
                        float px = cx + (float) Math.cos(angle) * rad;
                        float py = cy + (float) Math.sin(angle) * rad;
                        if (i == 0) path.moveTo(px, py);
                        else path.lineTo(px, py);
                    }
                    path.close();
                    canvas.drawPath(path, stroke);
                    break;
                case ICON_CLOUD:
                    box.set(cx - r * 1.05f, cy - r * 0.1f, cx + r * 1.05f, cy + r * 0.72f);
                    canvas.drawRoundRect(box, r * 0.42f, r * 0.42f, stroke);
                    canvas.drawCircle(cx - r * 0.22f, cy - r * 0.22f, r * 0.42f, stroke);
                    break;
                case ICON_CAST:
                    box.set(cx - r, cy - r * 0.72f, cx + r, cy + r * 0.52f);
                    canvas.drawRoundRect(box, r * 0.18f, r * 0.18f, stroke);
                    path.reset();
                    path.moveTo(cx, cy + r * 0.36f);
                    path.lineTo(cx - r * 0.42f, cy + r * 0.92f);
                    path.lineTo(cx + r * 0.42f, cy + r * 0.92f);
                    path.close();
                    canvas.drawPath(path, fill);
                    break;
                case ICON_GATEWAY:
                    canvas.drawCircle(cx, cy, r * 0.18f, fill);
                    for (float sc : new float[] {0.58f, 0.98f}) {
                        float rr = r * sc;
                        box.set(cx - rr, cy - rr, cx + rr, cy + rr);
                        canvas.drawArc(box, -42f, 84f, false, stroke);
                        canvas.drawArc(box, 138f, 84f, false, stroke);
                    }
                    break;
                case ICON_SYNC:
                    box.set(cx - r * 0.88f, cy - r * 0.88f, cx + r * 0.88f, cy + r * 0.88f);
                    canvas.drawArc(box, -155f, 130f, false, stroke);
                    canvas.drawArc(box, 25f, 130f, false, stroke);
                    break;
                case ICON_PRIVACY:
                    box.set(cx - r * 0.76f, cy - r * 0.08f, cx + r * 0.76f, cy + r * 0.86f);
                    canvas.drawRoundRect(box, r * 0.2f, r * 0.2f, stroke);
                    box.set(cx - r * 0.46f, cy - r * 0.86f, cx + r * 0.46f, cy + r * 0.06f);
                    canvas.drawArc(box, 180f, 180f, false, stroke);
                    break;
                default:
                    canvas.drawCircle(cx, cy, r * 0.34f, stroke);
                    for (int i = 0; i < 8; i++) {
                        double ang = Math.toRadians(i * 45);
                        float x1 = cx + (float) Math.cos(ang) * r * 0.62f;
                        float y1 = cy + (float) Math.sin(ang) * r * 0.62f;
                        float x2 = cx + (float) Math.cos(ang) * r * 1.0f;
                        float y2 = cy + (float) Math.sin(ang) * r * 1.0f;
                        canvas.drawLine(x1, y1, x2, y2, stroke);
                    }
                    break;
            }
        }
    }
}
