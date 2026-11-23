package com.pilipala.marcomovie;

import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Redesigned Mobile Discovery Home:
 * - Mode 0 ({@code 片源界面}): Top Liquid Glass source/depot capsules + filter button, optional hero
 *   banner with cover ambient color extraction, sticky horizontal category chips, compact Continue
 *   Watching row, and 3/5-column {@code 2:3} poster grid with pagination.
 * - Mode 1 ({@code TMDB 发现推荐}): Trending / Popular Movies / Popular TV / Top Rated shelves; tapping
 *   any title immediately cross-searches active CMS sources.
 */
final class MobileHomePage {
    private static String selectedCategoryId = "";
    private static String lastSiteKey = "";
    private static final Map<String, String> selectedFilters = new LinkedHashMap<>();

    private MobileHomePage() {}

    static void render(final MobileRootShell shell, final FrameLayout container) {
        final MainActivity a = shell.a;
        int homeMode = a.mobilePrefs().getInt(Prefs.HOME_MODE, 0);
        if (homeMode == 1) {
            renderTmdbDiscoveryHome(shell, container);
            return;
        }
        if (a.config == null || shell.activeSite == null) {
            renderEmptyWelcome(shell, container);
            return;
        }
        renderSourceHome(shell, container, shell.activeSite);
    }

    private static void renderEmptyWelcome(MobileRootShell shell, FrameLayout container) {
        MainActivity a = shell.a;
        ScrollView sv = new ScrollView(a);
        sv.setVerticalScrollBarEnabled(false);
        sv.setFillViewport(true);
        LinearLayout box = a.vertical();
        box.setGravity(Gravity.CENTER_HORIZONTAL);
        box.setPadding(a.dp(24), a.statusBarHeight() + a.dp(48), a.dp(24), a.dp(110));

        TextView badge = a.text("MARCO MOVIE MOBILE", 11.5f, a.mobileAccentColor());
        badge.setTypeface(null, Typeface.BOLD);
        badge.setLetterSpacing(0.14f);
        box.addView(badge);
        a.gap(box, 12);

        TextView headline = a.text("把今晚，留给好故事。", 26, Color.WHITE);
        headline.setTypeface(null, Typeface.BOLD);
        headline.setGravity(Gravity.CENTER);
        box.addView(headline);
        a.gap(box, 10);

        TextView desc = a.text(MainActivity.TOOL_DECLARATION, 13, MainActivity.MUTED);
        desc.setGravity(Gravity.CENTER);
        desc.setLineSpacing(0, 1.35f);
        box.addView(desc);
        a.gap(box, 26);

        addPillAction(
                a,
                box,
                "＋ 一键读取剪贴板导入配置",
                a.mobileAccentColor(),
                0xff08120e,
                () -> UiWidgets.pasteConfigFromClipboard(a));
        a.gap(box, 10);
        addPillAction(
                a,
                box,
                "输入配置网址 / 选择本地包 (.json/.js/.py/.zip)",
                0xff1e2824,
                Color.WHITE,
                () -> UiWidgets.showMobileImportDialog(a));
        a.gap(box, 10);
        addPillAction(
                a,
                box,
                "★ 启用 TMDB 全球趋势推荐首页",
                0xff1a222d,
                0xff93c5fd,
                () -> {
                    a.mobilePrefs().edit().putInt(Prefs.HOME_MODE, 1).apply();
                    shell.switchTab(MobileRootShell.TAB_HOME);
                });

        sv.addView(box, new ScrollView.LayoutParams(-1, -2));
        container.addView(sv, new FrameLayout.LayoutParams(-1, -1));
    }

    private static void addPillAction(
            MainActivity a,
            LinearLayout parent,
            String text,
            int bgColor,
            int textColor,
            Runnable action) {
        TextView btn = a.text(text, 14, textColor);
        btn.setTypeface(null, Typeface.BOLD);
        btn.setGravity(Gravity.CENTER);
        btn.setPadding(a.dp(18), a.dp(13), a.dp(18), a.dp(13));
        btn.setBackground(a.bg(bgColor, 999));
        UiWidgets.bindTouchFeedback(btn);
        btn.setOnClickListener(v -> action.run());
        parent.addView(btn, new LinearLayout.LayoutParams(-1, -2));
    }

    private static void renderSourceHome(
            final MobileRootShell shell, final FrameLayout container, final Cms.Site site) {
        final MainActivity a = shell.a;
        if (!site.key.equals(lastSiteKey)) {
            lastSiteKey = site.key;
            selectedCategoryId = "";
            selectedFilters.clear();
        }
        shell.setAmbientColor(SeasonParser.defaultAmbientForTitle(site.name));

        LinearLayout page = a.vertical();
        container.addView(page, new FrameLayout.LayoutParams(-1, -1));

        // 1. Pinned Top Glass Bar + Sticky Category Strip
        LinearLayout pinnedHeader = a.vertical();
        pinnedHeader.setPadding(a.dp(16), a.statusBarHeight() + a.dp(8), a.dp(16), a.dp(6));
        page.addView(pinnedHeader, new LinearLayout.LayoutParams(-1, -2));

        LinearLayout topRow = a.row();
        topRow.setGravity(Gravity.CENTER_VERTICAL);

        TextView srcCapsule = a.text("▾ " + site.name, 13.5f, Color.WHITE);
        srcCapsule.setTag("source-switcher");
        srcCapsule.setTypeface(null, Typeface.BOLD);
        srcCapsule.setSingleLine(true);
        srcCapsule.setEllipsize(TextUtils.TruncateAt.END);
        srcCapsule.setMaxWidth(a.dp(180));
        srcCapsule.setPadding(a.dp(14), a.dp(7), a.dp(14), a.dp(7));
        srcCapsule.setBackground(
                UiWidgets.glassBg(0xd41e2724, 0xc8141b18, a.dp(999), a.dp(0.8f), 0x38ffffff));
        UiWidgets.bindTouchFeedback(srcCapsule);
        srcCapsule.setOnClickListener(v -> shell.showQuickSourceAndModeSheet());
        topRow.addView(srcCapsule, new LinearLayout.LayoutParams(-2, -2));

        if (a.config != null && a.config.depots != null && a.config.depots.length() > 1) {
            TextView depotPill = a.text("多仓", 12, 0xff93c5fd);
            depotPill.setTypeface(null, Typeface.BOLD);
            depotPill.setPadding(a.dp(11), a.dp(6), a.dp(11), a.dp(6));
            depotPill.setBackground(
                    UiWidgets.glassBg(0x332563eb, 0x221d4ed8, a.dp(999), a.dp(0.8f), 0x5560a5fa));
            UiWidgets.bindTouchFeedback(depotPill);
            depotPill.setOnClickListener(v -> SourcePicker.showWarehouses(a));
            LinearLayout.LayoutParams dLp = new LinearLayout.LayoutParams(-2, -2);
            dLp.leftMargin = a.dp(8);
            topRow.addView(depotPill, dLp);
        }

        topRow.addView(new View(a), new LinearLayout.LayoutParams(0, 1, 1f));

        final TextView filterBtn = a.text("筛选", 12.5f, 0xffe5e7eb);
        filterBtn.setTypeface(null, Typeface.BOLD);
        filterBtn.setPadding(a.dp(13), a.dp(6), a.dp(13), a.dp(6));
        filterBtn.setBackground(
                UiWidgets.glassBg(0xcc222b28, 0xb8161d1b, a.dp(999), a.dp(0.8f), 0x30ffffff));
        filterBtn.setVisibility(View.GONE);
        UiWidgets.bindTouchFeedback(filterBtn);
        topRow.addView(filterBtn, new LinearLayout.LayoutParams(-2, -2));
        pinnedHeader.addView(topRow, new LinearLayout.LayoutParams(-1, -2));

        // Sticky horizontal category chips
        HorizontalScrollView catScroll = new HorizontalScrollView(a);
        catScroll.setHorizontalScrollBarEnabled(false);
        catScroll.setPadding(0, a.dp(8), 0, a.dp(2));
        final LinearLayout catRow = a.row();
        catScroll.addView(catRow);
        pinnedHeader.addView(catScroll, new LinearLayout.LayoutParams(-1, -2));

        // 2. Scrollable content area
        ScrollView sv = new ScrollView(a);
        sv.setVerticalScrollBarEnabled(false);
        sv.setClipToPadding(false);
        shell.bindScrollBehavior(sv);
        final LinearLayout body = a.vertical();
        body.setPadding(0, a.dp(4), 0, a.dp(106));
        sv.addView(body, new ScrollView.LayoutParams(-1, -2));
        page.addView(sv, new LinearLayout.LayoutParams(-1, 0, 1f));

        // Continue watching horizontal strip (shown on "推荐" tab when history exists)
        final LinearLayout historyWrap = a.vertical();
        body.addView(historyWrap, new LinearLayout.LayoutParams(-1, -2));
        renderContinueWatchingStrip(a, historyWrap);

        final FrameLayout heroHolder = new FrameLayout(a);
        body.addView(heroHolder, new LinearLayout.LayoutParams(-1, -2));

        final TextView statusView = a.text("正在连接片源…", 13, MainActivity.MUTED);
        statusView.setGravity(Gravity.CENTER);
        statusView.setPadding(a.dp(16), a.dp(28), a.dp(16), a.dp(28));
        body.addView(statusView, new LinearLayout.LayoutParams(-1, -2));

        final LinearLayout gridWrap = a.vertical();
        gridWrap.setPadding(a.dp(16), a.dp(4), a.dp(16), 0);
        body.addView(gridWrap, new LinearLayout.LayoutParams(-1, -2));

        final TextView moreBtn = a.text("加载更多影片", 13.5f, Color.WHITE);
        moreBtn.setTypeface(null, Typeface.BOLD);
        moreBtn.setGravity(Gravity.CENTER);
        moreBtn.setPadding(a.dp(18), a.dp(11), a.dp(18), a.dp(11));
        moreBtn.setBackground(
                UiWidgets.glassBg(0xcc242d2a, 0xb8181f1d, a.dp(999), a.dp(0.8f), 0x33ffffff));
        moreBtn.setVisibility(View.GONE);
        UiWidgets.bindTouchFeedback(moreBtn);
        LinearLayout.LayoutParams moreLp = new LinearLayout.LayoutParams(-1, -2);
        moreLp.setMargins(a.dp(16), a.dp(14), a.dp(16), a.dp(8));
        body.addView(moreBtn, moreLp);

        final List<Cms.Category> categories = new ArrayList<>();
        final List<Cms.Video> currentVideos = new ArrayList<>();
        final String[] filterSchemaHolder = {"{}"};
        final int[] curPage = {1};
        final int[] totalPages = {1};
        final int[] reqId = {0};
        final Runnable[] fetchListing = new Runnable[1];

        final Runnable rebuildChips =
                new Runnable() {
                    @Override
                    public void run() {
                        catRow.removeAllViews();
                        addCatChip(
                                a,
                                catRow,
                                "推荐",
                                "",
                                selectedCategoryId.isEmpty(),
                                () -> {
                                    selectedCategoryId = "";
                                    curPage[0] = 1;
                                    run();
                                    fetchListing[0].run();
                                });
                        for (final Cms.Category c : categories) {
                            addCatChip(
                                    a,
                                    catRow,
                                    c.name,
                                    c.id,
                                    c.id.equals(selectedCategoryId),
                                    () -> {
                                        selectedCategoryId = c.id;
                                        curPage[0] = 1;
                                        run();
                                        fetchListing[0].run();
                                    });
                        }
                        String targetCat =
                                selectedCategoryId.isEmpty() && !categories.isEmpty()
                                        ? categories.get(0).id
                                        : selectedCategoryId;
                        final List<VideoFilters.Definition> activeDefs =
                                VideoFilters.definitions(
                                        filterSchemaHolder[0], targetCat, currentVideos);
                        filterBtn.setVisibility(
                                activeDefs != null && !activeDefs.isEmpty()
                                        ? View.VISIBLE
                                        : View.GONE);
                        filterBtn.setText(
                                selectedFilters.isEmpty()
                                        ? "筛选"
                                        : ("筛选 · " + selectedFilters.size()));
                        filterBtn.setOnClickListener(
                                v -> {
                                    if (activeDefs == null || activeDefs.isEmpty()) return;
                                    VideoFilterDialog.show(
                                            a,
                                            activeDefs,
                                            selectedFilters,
                                            () -> {
                                                if (selectedCategoryId.isEmpty()
                                                        && !categories.isEmpty()) {
                                                    selectedCategoryId = categories.get(0).id;
                                                }
                                                curPage[0] = 1;
                                                run();
                                                fetchListing[0].run();
                                            });
                                });
                    }
                };

        fetchListing[0] =
                () -> {
                    final int myReq = ++reqId[0];
                    final int pageToLoad = curPage[0];
                    final String catId = selectedCategoryId;
                    historyWrap.setVisibility(catId.isEmpty() ? View.VISIBLE : View.GONE);
                    if (pageToLoad == 1) {
                        gridWrap.removeAllViews();
                        heroHolder.removeAllViews();
                        moreBtn.setVisibility(View.GONE);
                        statusView.setVisibility(View.VISIBLE);
                        statusView.setText("正在加载片单…");
                    } else {
                        moreBtn.setText("正在加载第 " + pageToLoad + " 页…");
                    }

                    // Instant snapshot hit for page 1 home
                    if (catId.isEmpty() && pageToLoad == 1) {
                        HomeScreen.Snapshot cached = a.homeData.get(site.key);
                        if (cached != null && !cached.videos.isEmpty()) {
                            categories.clear();
                            categories.addAll(cached.categories);
                            currentVideos.clear();
                            currentVideos.addAll(cached.videos);
                            filterSchemaHolder[0] = cached.filterSchema;
                            totalPages[0] = Math.max(1, cached.pages);
                            rebuildChips.run();
                            statusView.setVisibility(View.GONE);
                            presentVideos(shell, site, cached.videos, heroHolder, gridWrap, true);
                            return;
                        }
                    }

                    final int ticket = a.generation;
                    final String targetCatForDefs =
                            catId.isEmpty() && !categories.isEmpty() ? categories.get(0).id : catId;
                    final List<VideoFilters.Definition> defsSnapshot =
                            VideoFilters.definitions(
                                    filterSchemaHolder[0], targetCatForDefs, currentVideos);
                    a.submitPage(
                            () -> {
                                try {
                                    SourceEngine eng = a.engine(site);
                                    final List<Cms.Category> parsedCats;
                                    final Cms.Listing listing;
                                    final String homeRaw;
                                    if (catId.isEmpty() && pageToLoad == 1) {
                                        homeRaw = eng.home();
                                        parsedCats = Cms.categories(homeRaw);
                                        Cms.Listing cand =
                                                new org.json.JSONObject(homeRaw).has("list")
                                                        ? Cms.listing(homeRaw)
                                                        : new Cms.Listing();
                                        if (cand.videos.isEmpty()) {
                                            try {
                                                cand = Cms.listing(eng.homeVideos());
                                            } catch (Throwable ignored) {
                                            }
                                        }
                                        if (cand.videos.isEmpty() && !parsedCats.isEmpty()) {
                                            cand =
                                                    Cms.listing(
                                                            eng.category(parsedCats.get(0).id, 1));
                                        }
                                        listing = cand;
                                    } else {
                                        homeRaw = null;
                                        parsedCats = null;
                                        listing =
                                                Cms.listing(
                                                        eng.category(
                                                                catId,
                                                                pageToLoad,
                                                                VideoFilters.remoteValues(
                                                                        defsSnapshot,
                                                                        selectedFilters)));
                                    }
                                    final List<Cms.Video> displayList =
                                            VideoFilters.apply(
                                                    listing.videos, defsSnapshot, selectedFilters);
                                    a.learnTitles(listing.videos);
                                    a.ui.post(
                                            () -> {
                                                if (a.isFinishing()
                                                        || ticket != a.generation
                                                        || myReq != reqId[0]) return;
                                                if (pageToLoad == 1) currentVideos.clear();
                                                currentVideos.addAll(displayList);
                                                if (catId.isEmpty() && pageToLoad == 1) {
                                                    categories.clear();
                                                    if (parsedCats != null)
                                                        categories.addAll(parsedCats);
                                                    if (homeRaw != null)
                                                        filterSchemaHolder[0] = homeRaw;
                                                    HomeScreen.Snapshot snap =
                                                            new HomeScreen.Snapshot(
                                                                    displayList,
                                                                    new ArrayList<>(categories),
                                                                    "",
                                                                    listing.pageCount);
                                                    snap.filterSchema = filterSchemaHolder[0];
                                                    a.homeData.put(site.key, snap);
                                                    rebuildChips.run();
                                                }
                                                totalPages[0] = Math.max(1, listing.pageCount);
                                                statusView.setVisibility(
                                                        displayList.isEmpty() && pageToLoad == 1
                                                                ? View.VISIBLE
                                                                : View.GONE);
                                                if (displayList.isEmpty() && pageToLoad == 1) {
                                                    statusView.setText("当前分类暂无内容");
                                                }
                                                presentVideos(
                                                        shell,
                                                        site,
                                                        displayList,
                                                        heroHolder,
                                                        gridWrap,
                                                        catId.isEmpty() && pageToLoad == 1);
                                                boolean hasMore = pageToLoad < totalPages[0];
                                                moreBtn.setVisibility(
                                                        hasMore ? View.VISIBLE : View.GONE);
                                                if (hasMore) {
                                                    moreBtn.setText(
                                                            "加载更多 ("
                                                                    + pageToLoad
                                                                    + " / "
                                                                    + totalPages[0]
                                                                    + ")");
                                                }
                                            });
                                } catch (Exception e) {
                                    a.ui.post(
                                            () -> {
                                                if (a.isFinishing()
                                                        || ticket != a.generation
                                                        || myReq != reqId[0]) return;
                                                statusView.setVisibility(View.VISIBLE);
                                                statusView.setText(
                                                        "加载失败：" + a.message(e) + "（点击重试）");
                                                statusView.setOnClickListener(
                                                        v -> fetchListing[0].run());
                                            });
                                }
                            });
                };

        moreBtn.setOnClickListener(
                v -> {
                    curPage[0]++;
                    fetchListing[0].run();
                });

        rebuildChips.run();
        fetchListing[0].run();
    }

    private static void addCatChip(
            MainActivity a,
            LinearLayout row,
            String label,
            String id,
            boolean active,
            Runnable onTap) {
        int accent = a.mobileAccentColor();
        TextView chip = a.text(label, 12.5f, active ? 0xff08120e : 0xffe5e7eb);
        chip.setTag("home-tab:" + (id.isEmpty() ? "0" : id));
        chip.setTypeface(null, active ? Typeface.BOLD : Typeface.NORMAL);
        chip.setPadding(a.dp(14), a.dp(6), a.dp(14), a.dp(6));
        chip.setBackground(
                active
                        ? a.bg(accent, 999)
                        : UiWidgets.glassBg(
                                0xb81d2522, 0xb8141a18, a.dp(999), a.dp(0.7f), 0x26ffffff));
        UiWidgets.bindTouchFeedback(chip);
        chip.setOnClickListener(v -> onTap.run());
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
        lp.rightMargin = a.dp(8);
        row.addView(chip, lp);
    }

    private static void renderContinueWatchingStrip(MainActivity a, LinearLayout parent) {
        parent.removeAllViews();
        List<WatchHistory.Entry> items = a.watchHistory();
        if (items.isEmpty()) return;

        LinearLayout header = a.row();
        header.setGravity(Gravity.CENTER_VERTICAL);
        header.setPadding(a.dp(16), a.dp(4), a.dp(16), a.dp(6));
        TextView title = a.text("继续观看", 15, Color.WHITE);
        title.setTypeface(null, Typeface.BOLD);
        header.addView(title, new LinearLayout.LayoutParams(0, -2, 1f));
        TextView all = a.text("全部 ›", 12, MainActivity.MUTED);
        UiWidgets.bindTouchFeedback(all);
        all.setOnClickListener(v -> MobileRootShell.openTab(a, MobileRootShell.TAB_LIBRARY));
        header.addView(all);
        parent.addView(header);

        HorizontalScrollView hsv = new HorizontalScrollView(a);
        hsv.setHorizontalScrollBarEnabled(false);
        hsv.setPadding(a.dp(16), 0, a.dp(16), a.dp(10));
        hsv.setClipToPadding(false);
        LinearLayout row = a.row();
        hsv.addView(row);

        int limit = Math.min(10, items.size());
        for (int i = 0; i < limit; i++) {
            final WatchHistory.Entry e = items.get(i);
            LinearLayout card = a.row();
            card.setGravity(Gravity.CENTER_VERTICAL);
            card.setPadding(a.dp(8), a.dp(8), a.dp(12), a.dp(8));
            card.setBackground(
                    UiWidgets.glassBg(0xc41b2421, 0xc4131917, a.dp(16), a.dp(0.8f), 0x28ffffff));
            UiWidgets.bindTouchFeedback(card);
            card.setOnClickListener(v -> a.resumeHistory(e));
            card.setOnLongClickListener(
                    v -> {
                        new AppDialog.Builder(a)
                                .setTitle("移除续播记录？")
                                .setMessage(e.title)
                                .setNegativeButton("取消", null)
                                .setPositiveButton(
                                        "移除",
                                        (d, w) -> {
                                            a.prefs
                                                    .edit()
                                                    .putString(
                                                            Prefs.WATCH_HISTORY,
                                                            WatchHistory.remove(
                                                                    a.prefs.getString(
                                                                            Prefs.WATCH_HISTORY,
                                                                            "[]"),
                                                                    e.key()))
                                                    .apply();
                                            renderContinueWatchingStrip(a, parent);
                                        })
                                .show();
                        return true;
                    });

            ImageView pic = new ImageView(a);
            pic.setScaleType(ImageView.ScaleType.CENTER_CROP);
            pic.setBackground(a.bg(0xff232b28, 10));
            pic.setClipToOutline(true);
            if (e.poster != null && !e.poster.isEmpty()) a.poster(e.poster, pic);
            LinearLayout.LayoutParams pLp = new LinearLayout.LayoutParams(a.dp(44), a.dp(60));
            pLp.rightMargin = a.dp(10);
            card.addView(pic, pLp);

            LinearLayout col = a.vertical();
            TextView t = a.text(e.title, 13.5f, Color.WHITE);
            t.setTypeface(null, Typeface.BOLD);
            t.setSingleLine(true);
            t.setEllipsize(TextUtils.TruncateAt.END);
            col.addView(t);

            TextView sub = a.text(a.historyLabel(e), 11.5f, MainActivity.MUTED);
            sub.setSingleLine(true);
            sub.setEllipsize(TextUtils.TruncateAt.END);
            sub.setPadding(0, a.dp(3), 0, a.dp(5));
            col.addView(sub);

            float frac =
                    e.duration > 0
                            ? Math.max(0.05f, Math.min(1f, e.position / (float) e.duration))
                            : 0.2f;
            FrameLayout barTrack = new FrameLayout(a);
            barTrack.setBackground(a.bg(0x28ffffff, 999));
            View barFill = new View(a);
            barFill.setBackground(a.bg(a.mobileAccentColor(), 999));
            barTrack.addView(
                    barFill, new FrameLayout.LayoutParams(Math.round(a.dp(136) * frac), -1));
            col.addView(barTrack, new LinearLayout.LayoutParams(a.dp(136), a.dp(3)));

            card.addView(col, new LinearLayout.LayoutParams(a.dp(144), -2));
            LinearLayout.LayoutParams cLp = new LinearLayout.LayoutParams(-2, -2);
            cLp.rightMargin = a.dp(10);
            row.addView(card, cLp);
        }
        parent.addView(hsv, new LinearLayout.LayoutParams(-1, -2));
    }

    private static void presentVideos(
            MobileRootShell shell,
            final Cms.Site site,
            List<Cms.Video> videos,
            FrameLayout heroHolder,
            LinearLayout gridWrap,
            boolean allowHero) {
        final MainActivity a = shell.a;
        if (videos == null || videos.isEmpty()) return;

        int startIdx = 0;
        if (allowHero
                && a.mobilePrefs().getBoolean(Prefs.HOME_CAROUSEL, true)
                && heroHolder.getChildCount() == 0) {
            final Cms.Video featured = videos.get(0);
            startIdx = 1;
            shell.setAmbientColor(SeasonParser.defaultAmbientForTitle(featured.title));
            FrameLayout hero = new FrameLayout(a);
            hero.setClipToOutline(true);
            hero.setBackground(a.bg(0xff18201e, 20));

            ImageView img = new ImageView(a);
            img.setScaleType(ImageView.ScaleType.CENTER_CROP);
            if (featured.poster != null && !featured.poster.isEmpty()) {
                a.poster(featured.poster, img, true);
            }
            hero.addView(img, new FrameLayout.LayoutParams(-1, a.dp(208)));

            View scrim = new View(a);
            scrim.setBackground(
                    new GradientDrawable(
                            GradientDrawable.Orientation.TOP_BOTTOM,
                            new int[] {0x10000000, 0x88080c0b, 0xee070b0a}));
            hero.addView(scrim, new FrameLayout.LayoutParams(-1, a.dp(208)));

            LinearLayout copy = a.vertical();
            copy.setPadding(a.dp(16), a.dp(14), a.dp(16), a.dp(14));
            TextView tag = a.text("精选推荐", 11, a.mobileAccentColor());
            tag.setTypeface(null, Typeface.BOLD);
            copy.addView(tag);
            TextView hTitle = a.text(featured.title, 20, Color.WHITE);
            hTitle.setTypeface(null, Typeface.BOLD);
            hTitle.setSingleLine(true);
            hTitle.setEllipsize(TextUtils.TruncateAt.END);
            copy.addView(hTitle);
            if (featured.remarks != null && !featured.remarks.isEmpty()) {
                TextView rem = a.text(featured.remarks, 12, 0xffd1d5db);
                rem.setPadding(0, a.dp(2), 0, 0);
                copy.addView(rem);
            }
            hero.addView(copy, new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM));
            UiWidgets.bindTouchFeedback(hero);
            hero.setOnClickListener(v -> openVideoOrFolder(a, site, featured));

            FrameLayout.LayoutParams hLp = new FrameLayout.LayoutParams(-1, a.dp(208));
            hLp.setMargins(a.dp(16), a.dp(4), a.dp(16), a.dp(12));
            heroHolder.addView(hero, hLp);
        }

        float wDp = a.windowWidth() / a.getResources().getDisplayMetrics().density;
        int cols = (wDp >= 600 || !a.isPortrait()) ? 5 : 3;
        int gapPx = a.dp(10);
        int availW = Math.max(a.dp(240), a.windowWidth() - a.dp(32) - gapPx * (cols - 1));
        int cardW = availW / cols;
        int posterH = Math.round(cardW * 1.46f);

        LinearLayout row = null;
        int countInRow = 0;
        for (int i = startIdx; i < videos.size(); i++) {
            final Cms.Video v = videos.get(i);
            if (row == null || countInRow == cols) {
                row = a.row();
                LinearLayout.LayoutParams rLp = new LinearLayout.LayoutParams(-1, -2);
                rLp.bottomMargin = a.dp(12);
                gridWrap.addView(row, rLp);
                countInRow = 0;
            }
            LinearLayout card = buildPosterCard(a, cardW, posterH, v.title, v.remarks, v.poster);
            card.setOnClickListener(view -> openVideoOrFolder(a, site, v));
            LinearLayout.LayoutParams cLp = new LinearLayout.LayoutParams(0, -2, 1f);
            if (countInRow < cols - 1) cLp.rightMargin = gapPx;
            row.addView(card, cLp);
            countInRow++;
        }
        if (row != null && countInRow > 0 && countInRow < cols) {
            for (int pad = countInRow; pad < cols; pad++) {
                LinearLayout.LayoutParams pLp = new LinearLayout.LayoutParams(0, 1, 1f);
                if (pad < cols - 1) pLp.rightMargin = gapPx;
                row.addView(new View(a), pLp);
            }
        }
    }

    static LinearLayout buildPosterCard(
            MainActivity a,
            int cardW,
            int posterH,
            String title,
            String badgeText,
            String posterUrl) {
        LinearLayout card = a.vertical();
        FrameLayout box = new FrameLayout(a);
        box.setClipToOutline(true);
        box.setBackground(a.bg(0xff1a2220, 13));

        ImageView img = new ImageView(a);
        img.setScaleType(ImageView.ScaleType.CENTER_CROP);
        if (posterUrl != null && !posterUrl.isEmpty()) a.poster(posterUrl, img);
        box.addView(img, new FrameLayout.LayoutParams(-1, posterH));

        if (badgeText != null && !badgeText.trim().isEmpty()) {
            TextView rem = a.text(badgeText.trim(), 10f, Color.WHITE);
            rem.setSingleLine(true);
            rem.setEllipsize(TextUtils.TruncateAt.END);
            rem.setPadding(a.dp(6), a.dp(2), a.dp(6), a.dp(2));
            rem.setBackground(a.bg(0xb8090d0c, 6));
            FrameLayout.LayoutParams bLp =
                    new FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM | Gravity.RIGHT);
            bLp.setMargins(a.dp(5), 0, a.dp(5), a.dp(5));
            box.addView(rem, bLp);
        }
        card.addView(box, new LinearLayout.LayoutParams(-1, posterH));

        TextView t = a.text(title == null ? "" : title, 12.5f, 0xfff3f4f6);
        t.setMaxLines(2);
        t.setEllipsize(TextUtils.TruncateAt.END);
        t.setPadding(a.dp(2), a.dp(6), a.dp(2), 0);
        card.addView(t, new LinearLayout.LayoutParams(-1, -2));
        UiWidgets.bindTouchFeedback(card);
        return card;
    }

    static void openVideoOrFolder(MainActivity a, Cms.Site site, Cms.Video v) {
        if (v == null) return;
        if (a.redirectListing(site, v)) return;
        a.open(new MainActivity.Screen(() -> a.detail(site, v)), true);
    }

    /** Mode 1: TMDB Global Discovery Home with instant cross-source search upon tap. */
    private static void renderTmdbDiscoveryHome(
            final MobileRootShell shell, final FrameLayout container) {
        final MainActivity a = shell.a;
        ScrollView sv = new ScrollView(a);
        sv.setVerticalScrollBarEnabled(false);
        sv.setClipToPadding(false);
        shell.bindScrollBehavior(sv);

        final LinearLayout body = a.vertical();
        body.setPadding(a.dp(16), a.statusBarHeight() + a.dp(10), a.dp(16), a.dp(110));
        sv.addView(body, new ScrollView.LayoutParams(-1, -2));
        container.addView(sv, new FrameLayout.LayoutParams(-1, -1));

        LinearLayout topRow = a.row();
        topRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView modeCapsule = a.text("▾ ★ TMDB 发现推荐", 13.5f, Color.WHITE);
        modeCapsule.setTypeface(null, Typeface.BOLD);
        modeCapsule.setPadding(a.dp(14), a.dp(7), a.dp(14), a.dp(7));
        modeCapsule.setBackground(
                UiWidgets.glassBg(0xd41e2724, 0xc8141b18, a.dp(999), a.dp(0.8f), 0x44fbbf24));
        UiWidgets.bindTouchFeedback(modeCapsule);
        modeCapsule.setOnClickListener(v -> shell.showQuickSourceAndModeSheet());
        topRow.addView(modeCapsule);
        topRow.addView(new View(a), new LinearLayout.LayoutParams(0, 1, 1f));
        body.addView(topRow);
        a.gap(body, 14);

        if (!TmdbService.isConfigured(a)) {
            TextView tip =
                    a.text(
                            "尚未配置 TMDB API Key。在手机「设置 → 刮削、账号与 AI 服务」中填入你自己的 TMDB Key 后，即可浏览全球实时热门电影与剧集，并一键跨片源聚合检索。",
                            13.5f,
                            MainActivity.MUTED);
            tip.setLineSpacing(0, 1.4f);
            body.addView(tip);
            a.gap(body, 18);
            addPillAction(
                    a,
                    body,
                    "前往配置 TMDB API Key",
                    a.mobileAccentColor(),
                    0xff08120e,
                    () -> {
                        MobileRootShell.settingsSubPage = 5;
                        shell.switchTab(MobileRootShell.TAB_SETTINGS);
                    });
            a.gap(body, 10);
            addPillAction(
                    a,
                    body,
                    "切回片源默认首页",
                    0xff1e2824,
                    Color.WHITE,
                    () -> {
                        a.mobilePrefs().edit().putInt(Prefs.HOME_MODE, 0).apply();
                        shell.switchTab(MobileRootShell.TAB_HOME);
                    });
            return;
        }

        final TextView loading = a.text("正在同步 TMDB 全球榜单…", 13, MainActivity.MUTED);
        loading.setPadding(0, a.dp(24), 0, a.dp(24));
        loading.setGravity(Gravity.CENTER);
        body.addView(loading, new LinearLayout.LayoutParams(-1, -2));

        TmdbService.fetchDiscoveryAsync(
                a,
                feed -> {
                    loading.setVisibility(View.GONE);
                    if (feed == null
                            || (feed.trending.isEmpty()
                                    && feed.popularTv.isEmpty()
                                    && feed.popularMovies.isEmpty())) {
                        TextView err =
                                a.text(
                                        "TMDB 数据拉取失败，请检查 API Key 或配置 TMDB 反代地址。",
                                        13,
                                        MainActivity.MUTED);
                        body.addView(err);
                        return;
                    }
                    addTmdbShelf(a, body, "🔥 今日全球趋势", feed.trending);
                    addTmdbShelf(a, body, "📺 热门连载剧集", feed.popularTv);
                    addTmdbShelf(a, body, "🎬 热门院线电影", feed.popularMovies);
                    addTmdbShelf(a, body, "🏆 高分口碑佳作", feed.topRated);
                });
    }

    private static void addTmdbShelf(
            final MainActivity a,
            LinearLayout parent,
            String shelfTitle,
            List<TmdbService.MediaCard> items) {
        if (items == null || items.isEmpty()) return;
        TextView header = a.text(shelfTitle, 16.5f, Color.WHITE);
        header.setTypeface(null, Typeface.BOLD);
        header.setPadding(0, a.dp(8), 0, a.dp(8));
        parent.addView(header);

        HorizontalScrollView hsv = new HorizontalScrollView(a);
        hsv.setHorizontalScrollBarEnabled(false);
        LinearLayout row = a.row();
        hsv.addView(row);

        int cardW = a.dp(112);
        int posterH = a.dp(164);
        for (final TmdbService.MediaCard m : items) {
            String badge = m.rating > 0 ? String.format(Locale.US, "★ %.1f", m.rating) : m.year;
            LinearLayout card = buildPosterCard(a, cardW, posterH, m.title, badge, m.posterUrl);
            card.setOnClickListener(v -> MobileRootShell.openSearch(a, m.title));
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(cardW, -2);
            lp.rightMargin = a.dp(10);
            row.addView(card, lp);
        }
        LinearLayout.LayoutParams sLp = new LinearLayout.LayoutParams(-1, -2);
        sLp.bottomMargin = a.dp(14);
        parent.addView(hsv, sLp);
    }
}
