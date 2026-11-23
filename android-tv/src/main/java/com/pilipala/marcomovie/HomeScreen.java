package com.pilipala.marcomovie;

import android.graphics.Color;
import android.graphics.Rect;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.animation.DecelerateInterpolator;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.*;
import org.json.JSONObject;

/** Recent history above one category-based, vertically browsed library. */
final class HomeScreen {
    static final int MAX_RETAINED_CARDS = 360;
    final MainActivity a;
    final Cms.Site site;
    final int COLUMNS;
    final float navScale;
    final Map<View, String> tabIds = new HashMap<>();
    final List<View> historyCards = new ArrayList<>(), tabs = new ArrayList<>();
    final List<List<View>> rows = new ArrayList<>();
    LinearLayout historyHost, content;
    LinearLayout curatedHost;
    View curatedHeroBtn;
    int curatedHeroHeightPx;
    final int[] heroImageToken = new int[1];
    int tvContentLeftPadPx, tvContentRightPadPx;
    boolean fullBleedTvHero;
    final List<View> curatedDramaCards = new ArrayList<>(), curatedMovieCards = new ArrayList<>();
    TvCuratedHome.Catalog curatedCatalog;
    int curatedHeroIndex;
    android.widget.HorizontalScrollView categoryScroll;
    CategoryFlow filters;
    InlineFilters inlineFilters;
    HomeAmbient ambient;
    TextView status, source, filterToggle, more, earlier, allHistory;
    int ticket, request, posterWidth, gridEpoch;
    Runnable pendingGrid;
    Runnable pendingTabSwitch;

    /** Tag of the card that should take focus once drawn after "加载更多". */
    String pendingFocus;

    boolean busy, buildingTabs, applyingFilters, switchedOnFocus;
    Snapshot snapshot;
    State state;
    FrameLayout retainedRoot;
    LinearLayout retainedBody;
    android.widget.ScrollView retainedScroll;
    HomeDock retainedDock;
    int retainedWidth, retainedHeight, retainedEngineEpoch;
    float retainedFontScale;
    Map<String, Object> retainedAppearance;

    static final class Snapshot {
        long time = System.currentTimeMillis();
        final List<Cms.Video> videos;
        final List<Cms.Category> categories;
        final String skip;
        final int pages;
        String filterSchema = "{}";
        boolean recommendationsPending;

        Snapshot(List<Cms.Video> videos, List<Cms.Category> categories, String skip, int pages) {
            this.videos = videos;
            this.categories = categories;
            this.skip = skip;
            this.pages = pages;
        }
    }

    /** Navigation-entry state survives detail/back without changing the active category. */
    static final class State {
        String site, category = "";
        int engineEpoch;
        List<Cms.Video> videos = new ArrayList<>();
        int page = 1, pages = 1, windowStart = 0;
        boolean ready, initialized, filtersExpanded, library, categoryFailed;
        String activeFilterNote = "";
        boolean activeFilterLocalFallback;
        int homeScroll, libraryScroll;
        String homeFocus, libraryFocus;
        Snapshot snapshot;
        final Map<String, String> selectedFilters = new LinkedHashMap<>();
        final Map<String, Cms.Listing> categoryCache = new HashMap<>();

        State(String key) {
            site = key;
        }
    }

    HomeScreen(MainActivity activity, Cms.Site selected) {
        a = activity;
        site = selected;
        navScale = Prefs.clampNavScale(a.prefs.getInt(Prefs.NAV_SCALE_PERCENT, 100)) / 100f;
        COLUMNS =
                TvLayoutPolicy.responsiveHomeColumns(
                        a.windowWidth() / a.getResources().getDisplayMetrics().density,
                        a.prefs.getInt(Prefs.HOME_COLUMNS, 5),
                        a.formFactor,
                        a.isPortrait());
    }

    boolean active() {
        return ticket == a.generation && !a.isFinishing();
    }

    void show() {
        a.renderPage("", "", true);
        ambient = a.homeAmbient;
        ticket = a.generation;
        if (a.current != null) a.current.home = true;
        state = a.current == null ? null : a.current.homeState;
        if (state == null || !site.key.equals(state.site) || state.engineEpoch != a.engineEpoch) {
            state = new State(site.key);
            state.engineEpoch = a.engineEpoch;
            if (a.current != null) a.current.homeState = state;
        }
        boolean tvLeftDock = a.homeDock != null && a.homeDock.tvLeft;
        boolean tvTopBar = a.homeDock != null && a.homeDock.tvTopLabeled;
        boolean bottomDock = !tvLeftDock && a.useBottomDock();
        int rightPadDp = a.homeDock != null ? a.homeDock.sideMarginDp : 44;
        int bottomPadDp = Math.max(86, Math.round(50 * navScale) + 36);
        int leftPadDp =
                tvLeftDock
                        ? (a.homeDock != null
                                ? Math.max(84, a.homeDock.crossDp + 34)
                                : Math.max(92, Math.round(56 * navScale) + 38))
                        : rightPadDp;
        int topPadDp = tvTopBar ? (a.homeDock != null ? a.homeDock.topSafeInsetDp : 84) : 28;
        fullBleedTvHero = a.isTvDevice() && !a.privateMode && (tvTopBar || tvLeftDock);
        tvContentLeftPadPx = a.dp(leftPadDp);
        tvContentRightPadPx = a.dp(rightPadDp);
        if (bottomDock) {
            a.body.setPadding(a.dp(18), a.dp(16), a.dp(18), a.dp(bottomPadDp));
        } else if (fullBleedTvHero) {
            a.body.setPadding(0, 0, 0, a.dp(48));
        } else {
            a.body.setPadding(a.dp(leftPadDp), a.dp(topPadDp), a.dp(rightPadDp), a.dp(48));
        }
        a.body.setClipChildren(false);
        a.body.setClipToPadding(false);
        a.scroll.setClipChildren(false);
        float width = a.windowWidth() / a.getResources().getDisplayMetrics().density;
        int marginDp = bottomDock ? 36 : (leftPadDp + rightPadDp);
        posterWidth = Math.max(48, (int) ((width - marginDp - (COLUMNS - 1) * 18) / COLUMNS) - 8);
        curatedHeroHeightPx = 0;
        if (tvLeftDock && !fullBleedTvHero) {
            TextView homeTitle = a.text("首页", 28, MainActivity.WHITE);
            homeTitle.setTypeface(null, Typeface.BOLD);
            a.body.addView(homeTitle);
            a.gap(a.body, 18);
        }
        if (a.isTvDevice() && !a.privateMode) {
            curatedHost = a.vertical();
            curatedHost.setTag("home-curated-host");
            curatedHost.setClipChildren(false);
            curatedHost.setClipToPadding(false);
            a.body.addView(curatedHost, new LinearLayout.LayoutParams(-1, -2));
            curatedCatalog = TvCuratedHome.peekOrSeed();
            renderCuratedSection(curatedCatalog);
            TvCuratedHome.loadAsync(
                    a,
                    fresh -> {
                        if (!active() || fresh == null) return;
                        if (curatedCatalog != null
                                && curatedCatalog.live
                                && fresh == curatedCatalog) {
                            return;
                        }
                        View curF = a.getCurrentFocus();
                        String restoreCuratedTag =
                                (curF != null
                                                && curF.getTag() instanceof String
                                                && ((String) curF.getTag())
                                                        .startsWith("home-curated-"))
                                        ? (String) curF.getTag()
                                        : null;
                        curatedCatalog = fresh;
                        renderCuratedSection(fresh);
                        wireNavigation();
                        if (restoreCuratedTag != null && curatedHost != null) {
                            View match = curatedHost.findViewWithTag(restoreCuratedTag);
                            if (match != null && match.isShown()) match.requestFocus();
                            else if (curatedHeroBtn != null) curatedHeroBtn.requestFocus();
                        }
                    });
        }
        LinearLayout belowHeroWrap;
        if (fullBleedTvHero) {
            belowHeroWrap = a.vertical();
            belowHeroWrap.setClipChildren(false);
            belowHeroWrap.setClipToPadding(false);
            belowHeroWrap.setPadding(tvContentLeftPadPx, 0, tvContentRightPadPx, 0);
            a.body.addView(belowHeroWrap, new LinearLayout.LayoutParams(-1, -2));
        } else {
            belowHeroWrap = a.body;
        }
        historyHost = a.vertical();
        historyHost.setClipChildren(false);
        historyHost.setClipToPadding(false);
        belowHeroWrap.addView(historyHost, new LinearLayout.LayoutParams(-1, -2));
        historySection();
        LinearLayout libraryParent = belowHeroWrap;
        LinearLayout heading = a.row();
        heading.setGravity(Gravity.CENTER_VERTICAL);
        heading.setClipChildren(false);
        heading.setClipToPadding(false);
        heading.setPadding(0, a.dp(6), 0, a.dp(10));
        TextView title = a.text(a.isTvDevice() ? "片库" : "发现", 22, MainActivity.WHITE);
        title.setTypeface(null, Typeface.BOLD);
        heading.addView(title, new LinearLayout.LayoutParams(-2, -2));
        source = pill(site.name, "source-switcher", a::chooseSources);
        source.setPadding(a.dp(Math.round(14 * navScale)), 0, a.dp(Math.round(14 * navScale)), 0);
        source.setCompoundDrawablePadding(a.dp(9));
        source.setCompoundDrawables(null, null, new SourceChevron(a), null);
        source.setOnFocusChangeListener((v, f) -> styleSource(f));
        styleSource(false);
        source.setMaxWidth(a.dp(Math.round(220 * Math.max(1f, navScale))));
        source.setContentDescription("当前片源：" + site.name + "，按确认键切换");
        LinearLayout.LayoutParams sourceSize =
                new LinearLayout.LayoutParams(-2, a.dp(Math.round(34 * navScale)));
        sourceSize.leftMargin = a.dp(14);
        heading.addView(source, sourceSize);
        if (a.isTvDevice() && !SourceController.isConfigOrNetdiskSite(site)) {
            filterToggle = pill("筛选  ⌄", "home-filters", this::showFilters);
            filterToggle.setPadding(
                    a.dp(Math.round(14 * navScale)), 0, a.dp(Math.round(14 * navScale)), 0);
            UiCompat.setDefaultFocusHighlightEnabled(filterToggle, false);
            filterToggle.setOnFocusChangeListener((v, f) -> styleFilterToggle(f));
            styleFilterToggle(false);
            LinearLayout.LayoutParams filterSize =
                    new LinearLayout.LayoutParams(-2, a.dp(Math.round(34 * navScale)));
            filterSize.leftMargin = a.dp(10);
            heading.addView(filterToggle, filterSize);
        } else {
            filterToggle = null;
        }
        libraryParent.addView(heading);
        filters = new CategoryFlow(a, this::wireNavigation);
        filters.setPadding(0, a.dp(2), 0, a.dp(8));
        if (a.isTvDevice()) {
            categoryScroll = new android.widget.HorizontalScrollView(a);
            categoryScroll.setTag("home-category-scroll");
            categoryScroll.setHorizontalScrollBarEnabled(false);
            categoryScroll.setOverScrollMode(View.OVER_SCROLL_NEVER);
            categoryScroll.setFocusable(false);
            categoryScroll.setClipToPadding(false);
            categoryScroll.addView(
                    filters, new android.widget.HorizontalScrollView.LayoutParams(-2, -2));
            libraryParent.addView(categoryScroll, new LinearLayout.LayoutParams(-1, -2));
        } else {
            categoryScroll = null;
            libraryParent.addView(filters);
        }
        inlineFilters = new InlineFilters(this);
        libraryParent.addView(inlineFilters, new LinearLayout.LayoutParams(-1, -2));
        status = a.text("正在整理片单…", 13, MainActivity.MUTED);
        status.setPadding(a.dp(4), a.dp(12), 0, a.dp(12));
        libraryParent.addView(status);
        earlier =
                pill(
                        "查看前面的影片",
                        "home-earlier",
                        () -> showWindow(Math.max(0, state.windowStart - windowSize())));
        earlier.setVisibility(View.GONE);
        libraryParent.addView(earlier, new LinearLayout.LayoutParams(a.dp(180), a.dp(40)));
        content = a.vertical();
        content.setClipChildren(false);
        content.setClipToPadding(false);
        if (a.isTvDevice()) {
            content.setMinimumHeight(Math.max(a.dp(420), a.windowHeight() - a.dp(96)));
        }
        libraryParent.addView(content);
        more =
                pill(
                        "加载更多",
                        "home-load-more",
                        () -> {
                            if (snapshot == null
                                    || (snapshot.recommendationsPending
                                            && state.category.isEmpty())) {
                                loadHome();
                                return;
                            }
                            if (windowEnd() < state.videos.size()) {
                                showWindow(state.windowStart + windowSize());
                                return;
                            }
                            loadCategory(!state.ready);
                        });
        LinearLayout footer = a.row();
        footer.setClipChildren(false);
        footer.setClipToPadding(false);
        footer.setGravity(Gravity.CENTER);
        footer.setPadding(0, a.dp(14), 0, a.dp(8));
        footer.addView(more, new LinearLayout.LayoutParams(a.dp(180), a.dp(40)));
        libraryParent.addView(footer);
        more.setVisibility(View.GONE);
        a.scroll
                .getViewTreeObserver()
                .addOnScrollChangedListener(
                        () -> {
                            if (!active() || a.scroll == null) return;
                            int sy = a.scroll.getScrollY();
                            if (a.homeDock != null) a.homeDock.onScrollY(sy);
                            if (ambient != null) {
                                ambient.setScrollReveal(
                                        HomeAmbient.computeScrollReveal(sy, curatedHeroHeightPx));
                            }
                            if (sy <= 0) return;
                            View child = a.scroll.getChildAt(0);
                            if (child == null) return;
                            int diff = child.getBottom() - (a.scroll.getHeight() + sy);
                            if (diff <= a.dp(260)) {
                                maybeAutoLoadMore();
                            }
                        });
        wireNavigation();
        retainedRoot = a.root;
        retainedBody = a.body;
        retainedScroll = a.scroll;
        retainedDock = a.homeDock;
        retainedWidth = a.windowWidth();
        retainedHeight = a.windowHeight();
        retainedFontScale = a.getResources().getConfiguration().fontScale;
        retainedEngineEpoch = a.engineEpoch;
        retainedAppearance = appearance();
        if (a.current != null) a.current.retainedHome = this;
        Snapshot saved = state.snapshot != null ? state.snapshot : a.homeData.get(site.key);
        if (saved != null
                && (state.snapshot != null || System.currentTimeMillis() - saved.time < 300000)) {
            snapshot = saved;
            renderSnapshot();
            return;
        }
        if (!a.reduced && (site.api == null || !site.api.contains("fixture.test"))) {
            Snapshot disk = readDiskSnapshot(a, site.key);
            if (disk != null && !disk.videos.isEmpty()) {
                snapshot = disk;
                a.homeData.put(site.key, disk);
                renderSnapshot();
                long staleMs = a.isTvDevice() ? 1800000L : 300000L;
                boolean missingSchema =
                        disk.filterSchema == null || disk.filterSchema.trim().length() <= 2;
                if (System.currentTimeMillis() - disk.time >= staleMs
                        || (missingSchema && !disk.categories.isEmpty())) {
                    refreshHomeSilently();
                }
                return;
            }
        }
        loadHome();
    }

    static Cms.Listing parseHomeListing(String raw) {
        if (raw == null || raw.trim().isEmpty()) return new Cms.Listing();
        try {
            String trimmed = raw.trim();
            if (trimmed.startsWith("<")) {
                return Cms.listing(raw);
            }
            if (new JSONObject(raw).has("list")) {
                return Cms.listing(raw);
            }
        } catch (Throwable ignored) {
        }
        return new Cms.Listing();
    }

    void refreshHomeSilently() {
        final int token = request;
        a.submitPage(
                () -> {
                    commitLoadingSite(a, site.key);
                    try {
                        SourceEngine engine = a.engine(site);
                        String raw = engine.home();
                        RequestScope.checkCurrent();
                        List<Cms.Category> categories = Cms.categories(raw);
                        Cms.Listing list = parseHomeListing(raw);
                        clean(list.videos);
                        if (list.videos.isEmpty())
                            try {
                                list = Cms.listing(engine.homeVideos());
                                clean(list.videos);
                            } catch (Throwable ignored) {
                            }
                        RequestScope.checkCurrent();
                        String skip = "";
                        if (list.videos.isEmpty() && !categories.isEmpty()) {
                            skip = categories.get(0).id;
                            list = Cms.listing(engine.category(skip, 1));
                            clean(list.videos);
                        }
                        if (list.videos.isEmpty() && categories.isEmpty()) return;
                        RequestScope.checkCurrent();
                        final Snapshot fresh =
                                new Snapshot(list.videos, categories, skip, list.pageCount);
                        fresh.filterSchema = raw;
                        writeDiskSnapshot(a, site.key, fresh);
                        a.ui.post(
                                () -> {
                                    a.homeData.put(site.key, fresh);
                                    if (!active() || snapshot == null) return;
                                    boolean onDefaultTab =
                                            !busy
                                                    && token == request
                                                    && state != null
                                                    && (state.category == null
                                                            || state.category.isEmpty())
                                                    && state.page == 1;
                                    if (onDefaultTab) {
                                        boolean changed = !sameSnapshotContent(snapshot, fresh);
                                        snapshot = fresh;
                                        state.snapshot = fresh;
                                        if (changed) {
                                            state.ready = false;
                                            renderSnapshot();
                                        } else if (inlineFilters != null) {
                                            inlineFilters.render();
                                            updateFilterToggle();
                                            wireNavigation();
                                        }
                                    } else {
                                        snapshot.filterSchema = fresh.filterSchema;
                                        if (inlineFilters != null) {
                                            inlineFilters.render();
                                            updateFilterToggle();
                                            wireNavigation();
                                        }
                                    }
                                });
                    } catch (Throwable ignored) {
                    } finally {
                        commitLoadingSite(a, "");
                    }
                });
    }

    /** Compare every displayed or actionable value, including later cards and category metadata. */
    static boolean sameSnapshotContent(Snapshot old, Snapshot fresh) {
        if (old == fresh) return true;
        if (old == null
                || fresh == null
                || old.pages != fresh.pages
                || !Objects.equals(old.skip, fresh.skip)
                || !Objects.equals(old.filterSchema, fresh.filterSchema)
                || old.recommendationsPending != fresh.recommendationsPending
                || old.categories.size() != fresh.categories.size()
                || old.videos.size() != fresh.videos.size()) return false;
        for (int i = 0; i < old.categories.size(); i++) {
            Cms.Category left = old.categories.get(i), right = fresh.categories.get(i);
            if (!Objects.equals(left.id, right.id) || !Objects.equals(left.name, right.name))
                return false;
        }
        for (int i = 0; i < old.videos.size(); i++) {
            Cms.Video left = old.videos.get(i), right = fresh.videos.get(i);
            if (!Arrays.asList(
                                    left.id,
                                    left.title,
                                    left.poster,
                                    left.remarks,
                                    left.year,
                                    left.area,
                                    left.genre,
                                    left.actor,
                                    left.director,
                                    left.description,
                                    left.action,
                                    left.tag,
                                    left.doubanScore)
                            .equals(
                                    Arrays.asList(
                                            right.id,
                                            right.title,
                                            right.poster,
                                            right.remarks,
                                            right.year,
                                            right.area,
                                            right.genre,
                                            right.actor,
                                            right.director,
                                            right.description,
                                            right.action,
                                            right.tag,
                                            right.doubanScore))
                    || left.lines.size() != right.lines.size()) return false;
            for (int l = 0; l < left.lines.size(); l++) {
                Cms.Line a = left.lines.get(l), b = right.lines.get(l);
                if (!Objects.equals(a.name, b.name) || a.episodes.size() != b.episodes.size())
                    return false;
                for (int e = 0; e < a.episodes.size(); e++) {
                    Cms.Episode x = a.episodes.get(e), y = b.episodes.get(e);
                    if (!Objects.equals(x.name, y.name)
                            || !Objects.equals(x.url, y.url)
                            || !x.headers.equals(y.headers)
                            || !String.valueOf(x.media).equals(String.valueOf(y.media)))
                        return false;
                }
            }
        }
        return true;
    }

    Map<String, Object> appearance() {
        Map<String, Object> values = new LinkedHashMap<>();
        Map<String, ?> prefs = a.prefs.getAll();
        for (String key :
                new String[] {
                    Prefs.HOME_COLUMNS,
                    Prefs.HOME_ROWS,
                    Prefs.HOME_SECTIONS,
                    Prefs.HOME_AMBIENT,
                    Prefs.WALLPAPER_ENABLED,
                    Prefs.WALLPAPER_DIM,
                    Prefs.REDUCED,
                    Prefs.REDUCED_TRANSPARENCY,
                    Prefs.UI_SCALE_PERCENT,
                    Prefs.NAV_SCALE_PERCENT,
                    Prefs.TV_DOCK_POSITION,
                    Prefs.TV_NAVIGATION_MODE,
                    Prefs.TV_AMBIENT_PERCENT,
                    Prefs.TV_BG_MODE,
                    Prefs.TV_GLOW_PRESET,
                    Prefs.TV_GLOW_COLOR_LEFT,
                    Prefs.TV_GLOW_COLOR_RIGHT
                }) values.put(key, prefs.get(key));
        values.put("tv_nav_custom", TvNavConfig.signature(a));
        return values;
    }

    /** Reattach the exact home tree after detail/playback, without a catalogue request. */
    boolean resume() {
        if (retainedRoot == null
                || state == null
                || !state.ready
                || busy
                || retainedWidth != a.windowWidth()
                || retainedHeight != a.windowHeight()
                || retainedFontScale != a.getResources().getConfiguration().fontScale
                || retainedEngineEpoch != a.engineEpoch
                || !appearance().equals(retainedAppearance)
                || !site.key.equals(a.prefs.getString(Prefs.SELECTED_SITE, ""))) return false;
        a.preparePage(true);
        ticket = a.generation;
        request++;
        cancelGrid();
        a.root = retainedRoot;
        a.body = retainedBody;
        a.scroll = retainedScroll;
        a.homeDock = retainedDock;
        a.homeAmbient = ambient;
        a.setContentView(retainedRoot);
        historySection();
        int drawn = state.windowStart;
        for (List<View> row : rows) drawn += row.size();
        if (drawn < windowEnd()) appendCards(drawn, gridEpoch, true);
        resumeMissingPosters(retainedRoot);
        updateMore();
        updateFilterContinueButton();
        wireNavigation();
        return true;
    }

    void resumeMissingPosters(View view) {
        if (view instanceof ImageView
                && ((ImageView) view).getDrawable() == null
                && view.getTag() instanceof String) {
            a.poster((String) view.getTag(), (ImageView) view);
        }
        if (view instanceof android.view.ViewGroup) {
            android.view.ViewGroup group = (android.view.ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++)
                resumeMissingPosters(group.getChildAt(i));
        }
    }

    private static void commitLoadingSite(MainActivity a, String siteKey) {
        if (a == null || a.prefs == null) return;
        a.prefs.edit().putString(Prefs.LOADING_SITE, siteKey == null ? "" : siteKey).commit();
    }

    void loadHome() {
        if (busy) return;
        busy = true;
        status.setVisibility(View.VISIBLE);
        status.setText("正在整理片单…");
        more.setVisibility(View.GONE);
        int token = ++request;
        if (a.prefs != null) {
            a.prefs.edit().putString(Prefs.LOADING_SITE, site.key == null ? "" : site.key).apply();
        }
        a.submitPage(
                () -> {
                    commitLoadingSite(a, site.key);
                    try {
                        SourceEngine engine = a.engine(site);
                        String raw = engine.home();
                        RequestScope.checkCurrent();
                        List<Cms.Category> categories = Cms.categories(raw);
                        Cms.Listing list = parseHomeListing(raw);
                        clean(list.videos);
                        if (list.videos.isEmpty()
                                && !categories.isEmpty()
                                && !SourceController.isConfigOrNetdiskSite(site)) {
                            Snapshot navigation =
                                    new Snapshot(new ArrayList<>(), categories, "", 1);
                            navigation.filterSchema = raw;
                            navigation.recommendationsPending = true;
                            a.ui.post(
                                    () -> {
                                        if (!active() || token != request) return;
                                        snapshot = navigation;
                                        renderSnapshot();
                                        status.setText("正在读取推荐…");
                                    });
                        }
                        if (list.videos.isEmpty())
                            try {
                                list = Cms.listing(engine.homeVideos());
                                clean(list.videos);
                            } catch (Throwable ignored) {
                            }
                        RequestScope.checkCurrent();
                        String skip = "";
                        if (list.videos.isEmpty() && !categories.isEmpty()) {
                            skip = categories.get(0).id;
                            list = Cms.listing(engine.category(skip, 1));
                            clean(list.videos);
                        }
                        Snapshot result =
                                new Snapshot(list.videos, categories, skip, list.pageCount);
                        RequestScope.checkCurrent();
                        result.filterSchema = raw;
                        if (!a.reduced
                                && (site.api == null || !site.api.contains("fixture.test"))) {
                            a.worker.execute(() -> writeDiskSnapshot(a, site.key, result));
                        }
                        a.ui.post(
                                () -> {
                                    a.prefs.edit().putString(Prefs.LOADING_SITE, "").apply();
                                    if (!active() || token != request) return;
                                    busy = false;
                                    snapshot = result;
                                    a.homeData.put(site.key, result);
                                    renderSnapshot();
                                });
                    } catch (Throwable e) {
                        AppLog.w("HomeScreen", "loadHome failed for " + site.key, e);
                        a.ui.post(
                                () -> {
                                    a.prefs.edit().putString(Prefs.LOADING_SITE, "").apply();
                                    if (!active() || token != request) return;
                                    busy = false;
                                    status.setText(a.message(e));
                                    more.setText("重新加载");
                                    more.setVisibility(View.VISIBLE);
                                    wireNavigation();
                                    if (source != null && source.isShown()) source.requestFocus();
                                });
                    }
                });
    }

    private static java.io.File snapshotCacheFile(MainActivity a, String siteKey) {
        try {
            java.io.File dir = new java.io.File(a.getCacheDir(), "home_snap_v1");
            if (!dir.exists()) dir.mkdirs();
            java.security.MessageDigest md = java.security.MessageDigest.getInstance("SHA-256");
            byte[] digest =
                    md.digest(
                            (siteKey == null ? "" : siteKey)
                                    .getBytes(java.nio.charset.StandardCharsets.UTF_8));
            StringBuilder hex = new StringBuilder(32);
            for (int i = 0; i < 16 && i < digest.length; i++) {
                hex.append(String.format(java.util.Locale.US, "%02x", digest[i] & 0xff));
            }
            return new java.io.File(dir, hex + ".json");
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static void writeDiskSnapshot(MainActivity a, String siteKey, Snapshot snap) {
        if (a == null || snap == null || (snap.videos.isEmpty() && snap.categories.isEmpty()))
            return;
        java.io.File file = snapshotCacheFile(a, siteKey);
        if (file == null) return;
        try {
            JSONObject root = new JSONObject();
            root.put("skip", snap.skip == null ? "" : snap.skip);
            root.put("pages", snap.pages);
            root.put("filterSchema", snap.filterSchema == null ? "{}" : snap.filterSchema);
            org.json.JSONArray cats = new org.json.JSONArray();
            for (Cms.Category c : snap.categories) {
                JSONObject cj = new JSONObject();
                cj.put("id", c.id);
                cj.put("name", c.name);
                cats.put(cj);
            }
            root.put("categories", cats);
            org.json.JSONArray vids = new org.json.JSONArray();
            int limit = Math.min(40, snap.videos.size());
            for (int i = 0; i < limit; i++) {
                Cms.Video v = snap.videos.get(i);
                JSONObject vj = new JSONObject();
                vj.put("id", v.id == null ? "" : v.id);
                vj.put("title", v.title == null ? "" : v.title);
                vj.put("poster", v.poster == null ? "" : v.poster);
                vj.put("remarks", v.remarks == null ? "" : v.remarks);
                vj.put("year", v.year == null ? "" : v.year);
                vj.put("area", v.area == null ? "" : v.area);
                vj.put("genre", v.genre == null ? "" : v.genre);
                vj.put("actor", v.actor == null ? "" : v.actor);
                vj.put("director", v.director == null ? "" : v.director);
                vj.put("description", v.description == null ? "" : v.description);
                vj.put("tag", v.tag == null ? "" : v.tag);
                vj.put("action", v.action == null ? "" : v.action);
                vj.put("doubanScore", v.doubanScore == null ? "" : v.doubanScore);
                vj.put("doubanId", v.doubanId == null ? "" : v.doubanId);
                vids.put(vj);
            }
            root.put("videos", vids);
            byte[] bytes = root.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8);
            try (java.io.FileOutputStream out = new java.io.FileOutputStream(file)) {
                out.write(bytes);
            }
        } catch (Throwable ignored) {
        }
    }

    private static Snapshot readDiskSnapshot(MainActivity a, String siteKey) {
        java.io.File file = snapshotCacheFile(a, siteKey);
        if (file == null || !file.exists() || file.length() <= 0 || file.length() > 512 * 1024)
            return null;
        // Expire disk snapshot after 3 days
        if (System.currentTimeMillis() - file.lastModified() > 3L * 24 * 3600 * 1000) return null;
        try (java.io.InputStream in = new java.io.FileInputStream(file)) {
            JSONObject root = new JSONObject(Cms.read(in, 512 * 1024));
            String skip = root.optString("skip", "");
            int pages = Math.max(1, root.optInt("pages", 1));
            List<Cms.Category> categories = new ArrayList<>();
            org.json.JSONArray cats = root.optJSONArray("categories");
            if (cats != null) {
                for (int i = 0; i < cats.length(); i++) {
                    JSONObject cj = cats.optJSONObject(i);
                    if (cj != null) {
                        String id = cj.optString("id", "");
                        String name = cj.optString("name", "");
                        if (!id.isEmpty() && !name.isEmpty()) {
                            categories.add(new Cms.Category(id, name));
                        }
                    }
                }
            }
            List<Cms.Video> videos = new ArrayList<>();
            org.json.JSONArray vids = root.optJSONArray("videos");
            if (vids != null) {
                for (int i = 0; i < vids.length(); i++) {
                    JSONObject vj = vids.optJSONObject(i);
                    if (vj != null) {
                        Cms.Video v = new Cms.Video();
                        v.id = vj.optString("id", "");
                        v.title = vj.optString("title", "");
                        v.poster = vj.optString("poster", "");
                        v.remarks = vj.optString("remarks", "");
                        v.year = vj.optString("year", "");
                        v.area = vj.optString("area", "");
                        v.genre = vj.optString("genre", vj.optString("tag", ""));
                        v.actor = vj.optString("actor", "");
                        v.director = vj.optString("director", "");
                        v.description = vj.optString("description", "");
                        v.tag = vj.optString("tag", "");
                        v.action = vj.optString("action", "");
                        v.doubanScore = vj.optString("doubanScore", "");
                        v.doubanId = vj.optString("doubanId", "");
                        if (!v.id.isEmpty() && !v.title.isEmpty()) {
                            videos.add(v);
                        }
                    }
                }
            }
            if (videos.isEmpty()) return null;
            Snapshot snap = new Snapshot(videos, categories, skip, pages);
            snap.time = file.lastModified();
            snap.filterSchema = root.optString("filterSchema", "{}");
            return snap;
        } catch (Throwable ignored) {
            return null;
        }
    }

    private void renderCuratedSection(final TvCuratedHome.Catalog catalog) {
        if (curatedHost == null || catalog == null) return;
        curatedHost.removeAllViews();
        curatedHeroBtn = null;
        curatedHeroHeightPx = 0;
        curatedDramaCards.clear();
        curatedMovieCards.clear();

        if (!catalog.hero.isEmpty()) {
            if (curatedHeroIndex < 0 || curatedHeroIndex >= catalog.hero.size()) {
                curatedHeroIndex = 0;
            }
            View heroView = buildCuratedHeroCard(catalog.hero);
            int heroH = curatedHeroHeightPx > 0 ? curatedHeroHeightPx : a.dp(256);
            curatedHost.addView(heroView, new LinearLayout.LayoutParams(-1, heroH));
            a.gap(curatedHost, fullBleedTvHero ? 4 : 20);
        }
        if (!catalog.hotDramas.isEmpty()) {
            buildCuratedShelf(
                    curatedHost,
                    "近期热剧",
                    "home-curated-drama",
                    catalog.hotDramas,
                    curatedDramaCards);
            a.gap(curatedHost, 18);
        }
        if (!catalog.hotMovies.isEmpty()) {
            buildCuratedShelf(
                    curatedHost,
                    "热门电影",
                    "home-curated-movie",
                    catalog.hotMovies,
                    curatedMovieCards);
            a.gap(curatedHost, 22);
        }
        if (ambient != null) {
            int sy = a.scroll != null ? a.scroll.getScrollY() : 0;
            ambient.setScrollReveal(HomeAmbient.computeScrollReveal(sy, curatedHeroHeightPx));
        }
    }

    private View buildCuratedHeroCard(final List<Cms.Video> heroList) {
        float density = Math.max(0.5f, a.getResources().getDisplayMetrics().density);
        int winHDp = Math.round(a.windowHeight() / density);
        int heroHeightDp =
                fullBleedTvHero ? Math.max(304, Math.min(390, Math.round(winHDp * 0.59f))) : 256;
        curatedHeroHeightPx = fullBleedTvHero ? a.dp(heroHeightDp) : 0;

        final FrameLayout hero = new FrameLayout(a);
        hero.setTag("home-curated-hero");
        if (!fullBleedTvHero) {
            hero.setClipToOutline(true);
            GradientDrawable fallbackBg = new GradientDrawable();
            fallbackBg.setColor(0xff141822);
            fallbackBg.setCornerRadius(a.dp(20));
            hero.setBackground(fallbackBg);
        } else {
            hero.setBackground(null);
        }
        hero.setLayoutParams(new LinearLayout.LayoutParams(-1, a.dp(heroHeightDp)));

        // Keep artwork in a dedicated clipped transparent sibling layer so
        // FocusMotion.unclipAncestors
        // on the hero button never disables clipping and the feathered bottom melts straight into
        // HomeAmbient with zero horizontal cut line.
        FrameLayout artLayer = new FrameLayout(a);
        artLayer.setClipChildren(true);
        artLayer.setClipToPadding(true);
        artLayer.setClipToOutline(true);
        artLayer.setBackground(null);
        hero.addView(artLayer, new FrameLayout.LayoutParams(-1, -1));

        // Single hardware ImageView receiving the exact-aspect bottom-feathered hero bitmap.
        final ImageView heroArt = new ImageView(a);
        heroArt.setTag("home-hero-cover");
        heroArt.setScaleType(ImageView.ScaleType.FIT_XY);
        heroArt.setBackground(null);
        artLayer.addView(heroArt, new FrameLayout.LayoutParams(-1, -1));

        boolean tvTopBar = a.homeDock != null && a.homeDock.tvTopLabeled;
        LinearLayout info = a.vertical();
        info.setGravity(Gravity.BOTTOM | Gravity.START);
        info.setPadding(
                fullBleedTvHero ? tvContentLeftPadPx : a.dp(30),
                a.dp(fullBleedTvHero ? (tvTopBar ? 70 : 24) : 20),
                fullBleedTvHero ? tvContentRightPadPx : a.dp(30),
                a.dp(fullBleedTvHero ? 20 : 20));
        info.setClipChildren(false);
        info.setClipToPadding(false);

        TextView eyebrow = a.text("首页推荐 · 近期热门", 12f, 0xdceef4ff);
        eyebrow.setTypeface(null, Typeface.BOLD);
        eyebrow.setShadowLayer(a.dp(6), 0, a.dp(1), 0xb0000000);
        info.addView(eyebrow);
        a.gap(info, 5);

        final TextView titleTv = a.text("", fullBleedTvHero ? 31f : 28f, MainActivity.WHITE);
        titleTv.setTypeface(null, Typeface.BOLD);
        titleTv.setSingleLine(true);
        titleTv.setEllipsize(TextUtils.TruncateAt.END);
        titleTv.setShadowLayer(a.dp(12), 0, a.dp(2), 0xc8000000);
        info.addView(titleTv, new LinearLayout.LayoutParams(a.dp(540), -2));
        a.gap(info, 7);

        LinearLayout metaRow = a.row();
        metaRow.setGravity(Gravity.CENTER_VERTICAL);
        final TextView metaTv = a.text("", 14f, 0xe8ebebf5);
        metaTv.setSingleLine(true);
        metaTv.setEllipsize(TextUtils.TruncateAt.END);
        metaTv.setShadowLayer(a.dp(6), 0, a.dp(1), 0xaa000000);
        metaRow.addView(metaTv);

        final TextView scorePill = a.text("", 12f, 0xff101218);
        scorePill.setTypeface(null, Typeface.BOLD);
        scorePill.setSingleLine(true);
        scorePill.setPadding(a.dp(9), a.dp(2.5f), a.dp(9), a.dp(2.5f));
        scorePill.setBackground(a.bg(0xf2f5f5f7, 8));
        LinearLayout.LayoutParams scoreLp = new LinearLayout.LayoutParams(-2, -2);
        scoreLp.leftMargin = a.dp(10);
        metaRow.addView(scorePill, scoreLp);
        info.addView(metaRow, new LinearLayout.LayoutParams(-2, -2));
        a.gap(info, 9);

        final TextView descTv = a.text("", 13.5f, 0xd8dce4f2);
        descTv.setMaxLines(2);
        descTv.setEllipsize(TextUtils.TruncateAt.END);
        descTv.setLineSpacing(a.dp(3f), 1.08f);
        descTv.setShadowLayer(a.dp(6), 0, a.dp(1), 0xa8000000);
        info.addView(descTv, new LinearLayout.LayoutParams(a.dp(520), -2));
        a.gap(info, 18);

        LinearLayout actionRow = a.row();
        actionRow.setGravity(Gravity.CENTER_VERTICAL);
        actionRow.setClipChildren(false);

        final TextView playBtn = a.text("▶  立即观看", 14.5f, 0xff111318);
        playBtn.setTypeface(null, Typeface.BOLD);
        playBtn.setGravity(Gravity.CENTER);
        playBtn.setPadding(a.dp(26), 0, a.dp(26), 0);
        focusable(playBtn, "home-curated-hero-play");
        playBtn.setBackground(a.bg(0xfff5f5f7, 999));
        playBtn.setOnFocusChangeListener(
                (v, f) ->
                        FocusMotion.style(
                                a,
                                playBtn,
                                f,
                                0xdcf5f5f7,
                                0xffffffff,
                                999,
                                0xff111318,
                                0xff111318,
                                true,
                                1.05f));
        actionRow.addView(playBtn, new LinearLayout.LayoutParams(-2, a.dp(44)));

        final LinearLayout dotsRow = a.row();
        dotsRow.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout.LayoutParams dotsLp = new LinearLayout.LayoutParams(-2, -2);
        dotsLp.leftMargin = a.dp(18);
        actionRow.addView(dotsRow, dotsLp);

        final TextView swipeHint = a.text("◀ ▶ 切换热门", 11.5f, 0xaaebebf5);
        LinearLayout.LayoutParams shLp = new LinearLayout.LayoutParams(-2, -2);
        shLp.leftMargin = a.dp(14);
        actionRow.addView(swipeHint, shLp);

        info.addView(actionRow, new LinearLayout.LayoutParams(-2, -2));
        hero.addView(info, new FrameLayout.LayoutParams(-1, -1));

        final Runnable syncHeroLeftEdge =
                () -> {
                    boolean tvLeftDock = a.homeDock != null && a.homeDock.tvLeft;
                    if (tvLeftDock && curatedHeroIndex <= 0) {
                        a.homeDock.leftEdge(playBtn, false);
                    } else {
                        playBtn.setNextFocusLeftId(View.NO_ID);
                    }
                    swipeHint.setText(
                            tvLeftDock && curatedHeroIndex <= 0 ? "◀ 导航  ·  ▶ 切换热门" : "◀ ▶ 切换热门");
                };

        final Runnable bindHero =
                () -> {
                    if (heroList.isEmpty()) return;
                    int idx = Math.max(0, Math.min(heroList.size() - 1, curatedHeroIndex));
                    curatedHeroIndex = idx;
                    Cms.Video item = heroList.get(idx);
                    titleTv.setText(item.title == null ? "" : item.title);
                    metaTv.setText(formatCuratedHeroMeta(item));
                    if (item.doubanScore != null && !item.doubanScore.isEmpty()) {
                        scorePill.setText("评分 " + item.doubanScore);
                        scorePill.setVisibility(View.VISIBLE);
                    } else {
                        scorePill.setVisibility(View.GONE);
                    }
                    descTv.setText(formatCuratedHeroSummary(item));
                    syncHeroLeftEdge.run();

                    dotsRow.removeAllViews();
                    for (int i = 0; i < heroList.size(); i++) {
                        View dot = new View(a);
                        boolean activeDot = i == idx;
                        dot.setBackground(a.bg(activeDot ? 0xffffffff : 0x58ffffff, 999));
                        LinearLayout.LayoutParams dlp =
                                new LinearLayout.LayoutParams(a.dp(activeDot ? 20 : 6), a.dp(5));
                        if (i > 0) dlp.leftMargin = a.dp(5);
                        dotsRow.addView(dot, dlp);
                    }
                    final int heroTargetW = a.windowWidth();
                    final int heroTargetH = a.dp(heroHeightDp);
                    ImmersivePoster.loadOfficialLandscapeInto(
                            a,
                            item,
                            heroArt,
                            heroImageToken,
                            heroTargetW,
                            heroTargetH,
                            (c0, c1) -> {
                                if (ambient != null
                                        && (a.scroll == null
                                                || a.scroll.getScrollY() < heroTargetH / 3)) {
                                    ambient.followHeroColors(c0, c1);
                                }
                            });
                    if (heroList.size() > 1) {
                        ImmersivePoster.prewarmOfficialLandscape(
                                a, heroList.get((idx + 1) % heroList.size()));
                    }
                };

        playBtn.setOnClickListener(
                v -> {
                    if (heroList.isEmpty()) return;
                    int idx = Math.max(0, Math.min(heroList.size() - 1, curatedHeroIndex));
                    TvDetailHost.openCurated(a, heroList.get(idx));
                });
        playBtn.setOnKeyListener(
                (v, keyCode, ev) -> {
                    if (ev.getAction() == android.view.KeyEvent.ACTION_DOWN
                            && heroList.size() > 1
                            && (keyCode == android.view.KeyEvent.KEYCODE_DPAD_LEFT
                                    || keyCode == android.view.KeyEvent.KEYCODE_DPAD_RIGHT)) {
                        boolean tvLeftDock = a.homeDock != null && a.homeDock.tvLeft;
                        if (keyCode == android.view.KeyEvent.KEYCODE_DPAD_LEFT) {
                            int next =
                                    resolveCuratedHeroLeftIndex(
                                            tvLeftDock, curatedHeroIndex, heroList.size());
                            if (next < 0) return false;
                            curatedHeroIndex = next;
                        } else {
                            curatedHeroIndex = (curatedHeroIndex + 1) % heroList.size();
                        }
                        bindHero.run();
                        return true;
                    }
                    return false;
                });

        curatedHeroBtn = playBtn;
        bindHero.run();
        return hero;
    }

    /**
     * Resolves DPAD_LEFT on the curated hero play button: moves to the previous hero card whenever
     * {@code currentIndex > 0}, enters the left dock ({@code -1}) only at card 0 when the left
     * navigation dock is active, and wraps to the last card in top-dock mode.
     */
    static int resolveCuratedHeroLeftIndex(boolean tvLeftDock, int currentIndex, int heroCount) {
        if (heroCount <= 1) return tvLeftDock ? -1 : 0;
        if (currentIndex > 0) return currentIndex - 1;
        return tvLeftDock ? -1 : (heroCount - 1);
    }

    /** Formats Hero metadata line (Year · Region · Genre) without duplicate region/genre tokens. */
    static String formatCuratedHeroMeta(Cms.Video item) {
        if (item == null) return "";
        java.util.LinkedHashSet<String> seen = new java.util.LinkedHashSet<>();
        StringBuilder meta = new StringBuilder();
        String year = item.year == null ? "" : item.year.trim();
        if (!year.isEmpty() && seen.add(ImmersivePoster.normalizeFactTokenKey(year))) {
            meta.append(year);
        }
        String area = dedupMetaField(item.area, " / ", 2, seen);
        if (!area.isEmpty()) {
            if (meta.length() > 0) meta.append(" · ");
            meta.append(area);
        }
        String genre = dedupMetaField(item.genre, " ", 3, seen);
        if (!genre.isEmpty()) {
            if (meta.length() > 0) meta.append(" · ");
            meta.append(genre);
        }
        return meta.toString();
    }

    private static String dedupMetaField(
            String raw, String sep, int maxItems, java.util.Set<String> seen) {
        if (raw == null || raw.trim().isEmpty()) return "";
        String[] tokens = raw.trim().split("[,，、/|;；\\s]+");
        StringBuilder out = new StringBuilder();
        int added = 0;
        for (String token : tokens) {
            String clean = token.trim();
            if (clean.isEmpty()) continue;
            if (!seen.add(ImmersivePoster.normalizeFactTokenKey(clean))) continue;
            if (out.length() > 0) out.append(sep);
            out.append(clean);
            if (++added >= maxItems) break;
        }
        return out.toString();
    }

    /** Formats Hero subtitle without repeating year/country/genre from Douban card_subtitle. */
    static String formatCuratedHeroSummary(Cms.Video item) {
        if (item == null) return "点击即可从你已添加的片源自动匹配高清线路播放";
        String d = item.description == null ? "" : item.description.trim();
        if (!d.isEmpty() && !TvCuratedHome.looksLikeMetadataSubtitle(d)) {
            return d;
        }
        String actor = item.actor == null ? "" : item.actor.trim();
        if (!actor.isEmpty()) {
            return "主演：" + actor;
        }
        return "点击即可从你已添加的片源自动匹配高清线路播放";
    }

    /**
     * Keep horizontal curated shelf focus free across visible slots 1–3 before shifting the row.
     * Scrolls only when the focused card moves right of slot 3 (resting it at slot 3) or left of
     * slot 1 (resting it at slot 1).
     */
    static int computeShelfScrollX(
            int currentScrollX, int cardLeft, int slotStepPx, int leftMarginPx, int maxScrollX) {
        int clampedMax = Math.max(0, maxScrollX);
        int baseScroll = Math.max(0, Math.min(clampedMax, currentScrollX));
        int step = Math.max(1, slotStepPx);
        int minComfort = baseScroll + leftMarginPx;
        int maxComfort = baseScroll + leftMarginPx + step * 2;
        if (cardLeft > maxComfort) {
            return Math.max(0, Math.min(clampedMax, cardLeft - (leftMarginPx + step * 2)));
        }
        if (cardLeft < minComfort) {
            return Math.max(0, Math.min(clampedMax, cardLeft - leftMarginPx));
        }
        return baseScroll;
    }

    private void buildCuratedShelf(
            LinearLayout parent,
            String headingText,
            String tagPrefix,
            List<Cms.Video> items,
            List<View> outCards) {
        LinearLayout header = a.row();
        header.setGravity(Gravity.CENTER_VERTICAL);
        if (fullBleedTvHero) {
            header.setPadding(tvContentLeftPadPx, 0, tvContentRightPadPx, 0);
        }
        TextView h = a.text(headingText, 18.5f, MainActivity.WHITE);
        h.setTypeface(null, Typeface.BOLD);
        header.addView(h);
        TextView sub = a.text("  ·  点击从已添加片源播放", 12f, 0x99ebebf5);
        header.addView(sub);
        parent.addView(header, new LinearLayout.LayoutParams(-1, -2));
        a.gap(parent, 10);

        final android.widget.HorizontalScrollView hsv =
                new android.widget.HorizontalScrollView(a) {
                    @Override
                    protected int computeScrollDeltaToGetChildRectOnScreen(Rect rect) {
                        return 0;
                    }
                };
        hsv.setHorizontalScrollBarEnabled(false);
        hsv.setOverScrollMode(View.OVER_SCROLL_NEVER);
        hsv.setClipChildren(false);
        hsv.setClipToPadding(false);
        hsv.setFocusable(false);

        final int leftPad = fullBleedTvHero ? tvContentLeftPadPx : a.dp(2);
        final LinearLayout strip = a.row();
        strip.setClipChildren(false);
        strip.setClipToPadding(false);
        strip.setPadding(
                leftPad, a.dp(4), fullBleedTvHero ? tvContentRightPadPx : a.dp(12), a.dp(6));
        hsv.addView(strip, new android.widget.HorizontalScrollView.LayoutParams(-2, -2));
        parent.addView(hsv, new LinearLayout.LayoutParams(-1, -2));

        final int[] plannedScrollX = new int[] {0};
        int cardW = Math.max(122, Math.min(156, posterWidth));
        int count = Math.min(14, items.size());
        for (int i = 0; i < count; i++) {
            final Cms.Video item = items.get(i);
            LinearLayout card = a.vertical();
            card.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(4));
            card.setGravity(Gravity.CENTER_HORIZONTAL);
            card.setClipChildren(false);

            FrameLayout artWrap = new FrameLayout(a);
            ImageView art = new AmbientPoster();
            TvV17PosterCard.artwork(a, art);
            artWrap.addView(art, new FrameLayout.LayoutParams(-1, -1));
            TvV17PosterCard.attachDoubanBadge(a, artWrap, item);
            card.addView(artWrap, new LinearLayout.LayoutParams(a.dp(cardW), a.dp(cardW * 1.46f)));
            a.poster(item.poster, art);

            TextView name = a.text(item.title, 13f, 0xffd0d4df);
            single(name);
            name.setPadding(a.dp(2), a.dp(7), a.dp(2), 0);
            card.addView(name, new LinearLayout.LayoutParams(-1, a.dp(26)));

            focusable(card, tagPrefix + ":" + i);
            TvFocusFrame.attachCard(card, tagPrefix);
            outline(card, false, 13, Color.TRANSPARENT);
            card.setContentDescription(item.title);
            card.setOnClickListener(v -> TvDetailHost.openCurated(a, item));
            card.setOnFocusChangeListener(
                    (v, f) -> {
                        TvV17PosterCard.focus(a, card, name, f);
                        if (f && ambient != null) ambient.follow(art);
                        if (f) {
                            int stepPx =
                                    strip.getChildCount() >= 2
                                                    && strip.getChildAt(1).getLeft()
                                                            > strip.getChildAt(0).getLeft()
                                            ? (strip.getChildAt(1).getLeft()
                                                    - strip.getChildAt(0).getLeft())
                                            : (v.getWidth() + a.dp(12));
                            int maxScroll = Math.max(0, strip.getWidth() - hsv.getWidth());
                            int refScroll =
                                    maxScroll == 0 ? 0 : Math.min(plannedScrollX[0], maxScroll);
                            int targetX =
                                    computeShelfScrollX(
                                            refScroll, v.getLeft(), stepPx, leftPad, maxScroll);
                            if (targetX != plannedScrollX[0]) {
                                plannedScrollX[0] = targetX;
                                if (a.reduced) hsv.scrollTo(targetX, 0);
                                else hsv.smoothScrollTo(targetX, 0);
                            }
                        }
                    });
            if (i == 0
                    && ambient != null
                    && (ambient.wanted == null || !ambient.wanted.isAttachedToWindow())) {
                ambient.follow(art);
            }
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
            if (i + 1 < count) lp.rightMargin = a.dp(12);
            strip.addView(card, lp);
            outCards.add(card);
        }
    }

    void historySection() {
        if (historyHost == null) return;
        historyHost.removeAllViews();
        historyCards.clear();
        allHistory = null;
        if (a.isTvDevice()) return;
        List<WatchHistory.Entry> entries = a.watchHistory();
        if (entries.isEmpty()) return;
        boolean compactStack = a.useBottomDock();
        LinearLayout section = a.vertical();
        section.setTag("home-history-section");
        section.setGravity(Gravity.TOP);
        section.setClipChildren(false);
        section.setClipToPadding(false);
        historyHost.addView(section, new LinearLayout.LayoutParams(-1, -2));
        LinearLayout heading = a.row();
        heading.setClipChildren(false);
        heading.setClipToPadding(false);
        TextView historyTitle = a.text(a.isTvDevice() ? "继续观看" : "历史记录", 17, MainActivity.WHITE);
        historyTitle.setTag("home-history-title");
        historyTitle.setTypeface(null, Typeface.BOLD);
        heading.addView(historyTitle, new LinearLayout.LayoutParams(0, -2, 1));
        allHistory =
                pill(
                        "全部历史  ›",
                        "home-history-all",
                        () -> a.open(new MainActivity.Screen(a::historyPage), true));
        heading.addView(
                allHistory, new LinearLayout.LayoutParams(-2, a.dp(Math.round(30 * navScale))));
        section.addView(heading, new LinearLayout.LayoutParams(-1, -2));
        a.gap(section, a.isTvDevice() ? 10 : 6);
        LinearLayout recent = compactStack ? a.vertical() : a.row();
        if (!compactStack) recent.setWeightSum(4);
        recent.setTag("home-history-list");
        recent.setClipChildren(false);
        recent.setClipToPadding(false);
        section.addView(recent, new LinearLayout.LayoutParams(-1, -2));
        int count = Math.min(4, entries.size());
        for (int i = 0; i < count; i++) {
            LinearLayout.LayoutParams cell =
                    compactStack
                            ? new LinearLayout.LayoutParams(-1, a.dp(72))
                            : new LinearLayout.LayoutParams(0, a.dp(72), 1);
            boolean last = i == count - 1;
            cell.rightMargin = a.dp(compactStack ? 0 : (last ? (4 - count) * 12 : 12));
            cell.bottomMargin = a.dp(compactStack && !last ? 10 : 0);
            final WatchHistory.Entry e = entries.get(i);
            LinearLayout card = a.row();
            card.setPadding(a.dp(10), a.dp(7), a.dp(14), a.dp(7));
            int cardResting = a.isTvDevice() ? 0xa4191f2b : 0xff222228;
            card.setBackground(
                    a.isTvDevice()
                            ? TvV17Surface.rounded(cardResting, a.dp(16), 0x24ffffff, a.dp(1))
                            : a.bg(cardResting, 14));
            ImageView image = new AmbientPoster();
            image.setScaleType(ImageView.ScaleType.CENTER_CROP);
            image.setBackground(a.bg(0xff303038, 8));
            image.setClipToOutline(true);
            LinearLayout.LayoutParams art = new LinearLayout.LayoutParams(a.dp(42), a.dp(60));
            art.rightMargin = a.dp(12);
            card.addView(image, art);
            a.poster(e.poster, image);
            LinearLayout info = a.vertical();
            info.setGravity(Gravity.CENTER_VERTICAL);
            card.addView(info, new LinearLayout.LayoutParams(0, -1, 1));
            TextView name = a.text(e.title, 14.5f, MainActivity.WHITE);
            name.setTypeface(null, Typeface.BOLD);
            single(name);
            info.addView(name);
            a.gap(info, 5);
            TextView detail = a.text(a.historyLabel(e), 11.5f, MainActivity.MUTED);
            single(detail);
            info.addView(detail);
            a.gap(info, 8);
            FrameLayout track = new FrameLayout(a);
            track.setBackground(a.bg(0x38ffffff, 2));
            track.setClipToOutline(true);
            info.addView(track, new LinearLayout.LayoutParams(-1, a.dp(3)));
            View progress = new View(a);
            progress.setBackgroundColor(0xff0a84ff);
            float fraction =
                    e.duration > 0 ? Math.max(0, Math.min(1, e.position / (float) e.duration)) : 0;
            track.addView(progress, new FrameLayout.LayoutParams(0, -1));
            track.addOnLayoutChangeListener(
                    (v, l, t, r, b, ol, ot, or, ob) -> {
                        android.view.ViewGroup.LayoutParams p = progress.getLayoutParams();
                        int w = Math.round((r - l) * fraction);
                        if (p.width != w) {
                            p.width = w;
                            progress.setLayoutParams(p);
                        }
                    });
            focusable(card, "home-history:" + i);
            outline(card, false, a.isTvDevice() ? 16 : 14, cardResting);
            card.setContentDescription(e.title + "，" + a.historyLabel(e));
            card.setOnClickListener(v -> a.resumeHistory(e));
            card.setOnFocusChangeListener(
                    (v, f) -> {
                        outline(card, f, a.isTvDevice() ? 16 : 14, cardResting);
                        if (f && ambient != null) ambient.follow(image);
                        if (f && !a.reduced && a.config != null) {
                            v.postDelayed(
                                    () -> {
                                        if (v.hasFocus() && active() && a.config != null) {
                                            for (Cms.Site s : a.config.sites) {
                                                if (s.key.equals(e.site)) {
                                                    Cms.Video listing = new Cms.Video();
                                                    listing.id = e.id;
                                                    listing.title = e.title;
                                                    listing.poster = e.poster;
                                                    SourceController.prefetchDetail(a, s, listing);
                                                    break;
                                                }
                                            }
                                        }
                                    },
                                    500);
                        }
                    });
            if (i == 0
                    && ambient != null
                    && (ambient.wanted == null || !ambient.wanted.isAttachedToWindow()))
                ambient.follow(image);
            recent.addView(card, cell);
            historyCards.add(card);
        }
        a.gap(historyHost, a.isTvDevice() ? 22 : 4);
    }

    void renderSnapshot() {
        a.prefs.edit().putString(Prefs.LOADING_SITE, "").apply();
        state.snapshot = snapshot;
        boolean first = !state.initialized;
        if (first) {
            state.initialized = true;
            if (SourceController.isConfigOrNetdiskSite(site) && !snapshot.skip.isEmpty()) {
                state.category = snapshot.skip;
                if (!snapshot.videos.isEmpty()) {
                    Cms.Listing initial = new Cms.Listing();
                    initial.videos.addAll(snapshot.videos);
                    initial.pageCount = snapshot.pages;
                    state.categoryCache.put(snapshot.skip, initial);
                }
            } else {
                state.category = "";
            }
        }
        buildTabs();
        if (first && a.current != null && a.current.focus == null) {
            View initial =
                    curatedHeroBtn != null && curatedHeroBtn.isShown()
                            ? curatedHeroBtn
                            : (!historyCards.isEmpty() ? historyCards.get(0) : selectedTab());
            a.current.focus = String.valueOf(initial.getTag());
            restoreFocus();
        }
        if (state.ready) {
            drawGrid(false);
            restoreFocus();
        } else choose(state.category, false);
    }

    void reloadCurrentCategory() {
        if (!active() || site == null) return;
        a.homeData.remove(site.key);
        state.categoryCache.clear();
        if (state.category.isEmpty() && snapshot != null && !snapshot.skip.isEmpty()) {
            state.category = snapshot.skip;
        }
        if (state.category.isEmpty()) {
            a.refresh();
            return;
        }
        state.ready = false;
        busy = false;
        choose(state.category, false);
    }

    void buildTabs() {
        buildingTabs = true;
        filters.removeAllViews();
        filters.lines.clear();
        tabs.clear();
        tabIds.clear();
        boolean configSite = SourceController.isConfigOrNetdiskSite(site);
        boolean tv = a.isTvDevice();
        int tabIdx = 0;
        if (!configSite || snapshot.skip.isEmpty()) {
            addTab("推荐", "", tabIdx++);
        }
        int visible =
                tv
                        ? Math.min(128, snapshot.categories.size())
                        : configSite
                                ? Math.min(16, snapshot.categories.size())
                                : Math.min(4, snapshot.categories.size());
        for (int i = 0; i < visible; i++) {
            Cms.Category c = snapshot.categories.get(i);
            addTab(c.name, c.id, tabIdx++);
        }
        if (snapshot.categories.size() > visible) {
            TextView extra =
                    pill(
                            "更多分类  ⌄",
                            "home-category-more",
                            () -> {
                                String[] names = new String[snapshot.categories.size()];
                                int selected = -1;
                                for (int i = 0; i < names.length; i++) {
                                    Cms.Category c = snapshot.categories.get(i);
                                    names[i] = c.name;
                                    if (c.id.equals(state.category)) selected = i;
                                }
                                new AppDialog.Builder(a)
                                        .setTitle("选择分类")
                                        .wrapChoices()
                                        .setSingleChoiceItems(
                                                names,
                                                selected,
                                                (d, n) ->
                                                        choose(snapshot.categories.get(n).id, true))
                                        .setNegativeButton("关闭", null)
                                        .show();
                            });
            extra.setOnFocusChangeListener((v, f) -> updateTabs());
            addTabView(extra);
        }
        if (!tv && !configSite) {
            addTabView(pill("筛选", "home-filters", this::showFilters));
        }
        updateTabs();
        wireNavigation();
        buildingTabs = false;
    }

    List<VideoFilters.Definition> filterDefinitions() {
        String category = state.category;
        if (category.isEmpty() && !snapshot.categories.isEmpty())
            category = snapshot.categories.get(0).id;
        Cms.Listing cachedCat = state.categoryCache.get(category);
        List<Cms.Video> pool =
                cachedCat != null && !cachedCat.videos.isEmpty()
                        ? cachedCat.videos
                        : (state.selectedFilters.isEmpty() && !state.videos.isEmpty()
                                ? state.videos
                                : snapshot.videos);
        List<VideoFilters.Definition> definitions =
                VideoFilters.definitions(snapshot.filterSchema, category, pool);
        if (site.supported())
            for (VideoFilters.Definition def : definitions) {
                if (!VideoFilters.allowedKey(def.key)) def.remote = false;
            }
        return definitions;
    }

    void styleFilterToggle(boolean focused) {
        if (filterToggle == null) return;
        boolean hasActive = state != null && !state.selectedFilters.isEmpty();
        int idleFill = hasActive ? 0xaa2563eb : 0x66344352;
        int focusFill = hasActive ? 0xff3b82f6 : 0xff344452;
        FocusMotion.style(
                a,
                filterToggle,
                focused,
                idleFill,
                focusFill,
                17,
                hasActive ? Color.WHITE : 0xffd7e2ed,
                Color.WHITE,
                true,
                1.02f);
    }

    void updateFilterToggle() {
        if (filterToggle == null || state == null) return;
        boolean show = !SourceController.isConfigOrNetdiskSite(site);
        filterToggle.setVisibility(show ? View.VISIBLE : View.GONE);
        if (!show) return;
        String base =
                state.selectedFilters.isEmpty() ? "筛选" : "筛选 · " + state.selectedFilters.size();
        filterToggle.setText(base + (state.filtersExpanded ? "  ⌃" : "  ⌄"));
        filterToggle.setContentDescription(
                base + "，按确认键" + (state.filtersExpanded ? "收起筛选" : "展开筛选"));
        styleFilterToggle(filterToggle.hasFocus());
    }

    void showFilters() {
        if (snapshot == null || SourceController.isConfigOrNetdiskSite(site)) return;
        if (a.isTvDevice()) {
            if (state.category.isEmpty() && !snapshot.categories.isEmpty()) {
                boolean wasApplying = applyingFilters;
                applyingFilters = true;
                try {
                    String firstCat = snapshot.categories.get(0).id;
                    state.category = firstCat;
                    state.filtersExpanded = true;
                    state.ready = false;
                    busy = false;
                    choose(firstCat, false);
                    View target = inlineFilters.firstSelectedChip();
                    if (target != null) target.requestFocus();
                } finally {
                    applyingFilters = wasApplying;
                }
                return;
            }
            if (state.category.isEmpty()) {
                a.toast("当前片源暂无可筛选的分类");
                return;
            }
            boolean wasApplying = applyingFilters;
            applyingFilters = true;
            try {
                state.filtersExpanded = !state.filtersExpanded;
                inlineFilters.render();
                updateTabs();
                wireNavigation();
                if (state.filtersExpanded) {
                    View target = inlineFilters.firstSelectedChip();
                    if (target != null) target.requestFocus();
                }
            } finally {
                applyingFilters = wasApplying;
            }
            return;
        }
        List<VideoFilters.Definition> definitions = filterDefinitions();
        String[] labels = new String[definitions.size() + 1];
        for (int i = 0; i < definitions.size(); i++) {
            VideoFilters.Definition def = definitions.get(i);
            labels[i] = def.label + "：" + def.labelFor(state.selectedFilters.get(def.dimension));
        }
        labels[definitions.size()] = "清除全部筛选";
        new AppDialog.Builder(a)
                .setTitle("影视筛选")
                .wrapChoices()
                .setItems(
                        labels,
                        (dialog, index) -> {
                            if (index == definitions.size()) {
                                if (!state.selectedFilters.isEmpty()) {
                                    state.selectedFilters.clear();
                                    applyFilters();
                                }
                                return;
                            }
                            VideoFilters.Definition def = definitions.get(index);
                            String[] options = new String[def.choices.size()];
                            int checked = 0;
                            for (int n = 0; n < options.length; n++) {
                                options[n] = def.choices.get(n).label;
                                if (def.choices
                                        .get(n)
                                        .value
                                        .equals(state.selectedFilters.get(def.dimension)))
                                    checked = n;
                            }
                            new AppDialog.Builder(a)
                                    .setTitle(def.label + (def.remote ? "" : " · 按影片资料筛选"))
                                    .wrapChoices()
                                    .setSingleChoiceItems(
                                            options,
                                            checked,
                                            (choiceDialog, n) -> {
                                                String value = def.choices.get(n).value;
                                                if (value.isEmpty())
                                                    state.selectedFilters.remove(def.dimension);
                                                else
                                                    state.selectedFilters.put(def.dimension, value);
                                                applyFilters();
                                            })
                                    .setNegativeButton("取消", null)
                                    .show();
                        })
                .setNegativeButton("关闭", null)
                .show();
    }

    void applyFilters() {
        String category = state.category;
        if (category.isEmpty()
                && !state.selectedFilters.isEmpty()
                && !snapshot.categories.isEmpty()) {
            category = snapshot.categories.get(0).id;
        }
        // A new filter starts at page one; detail/back keeps this exact state.
        View currentFocus = a.getCurrentFocus();
        String currentTag = currentFocus == null ? "" : String.valueOf(currentFocus.getTag());
        boolean fromSummaryReset = "home-filter-reset".equals(currentTag) && !state.filtersExpanded;
        String focusTag =
                currentTag.startsWith("home-filter:")
                                || ("home-filter-reset".equals(currentTag) && state.filtersExpanded)
                        ? currentTag
                        : a.isTvDevice()
                                ? (fromSummaryReset
                                        ? "home-video:0"
                                        : String.valueOf(selectedTab().getTag()))
                                : "home-filters";
        applyingFilters = true;
        try {
            if (fromSummaryReset && a.isTvDevice()) {
                selectedTab().requestFocus();
            }
            state.category = category;
            state.ready = false;
            busy = false;
            if (a.current != null) a.current.focus = focusTag;
            choose(category, false);
            if (fromSummaryReset && a.isTvDevice()) {
                View firstCard = a.root.findViewWithTag("home-video:0");
                if (firstCard != null) firstCard.requestFocus();
                else pendingFocus = "home-video:0";
            } else {
                View filter = a.root.findViewWithTag(focusTag);
                if (filter != null) {
                    filter.requestFocus();
                }
            }
        } finally {
            applyingFilters = false;
        }
    }

    void addTab(String label, String id, int index) {
        TextView button =
                pill(
                        label,
                        "home-tab:" + index,
                        () -> {
                            if (pendingTabSwitch != null) {
                                a.ui.removeCallbacks(pendingTabSwitch);
                                pendingTabSwitch = null;
                            }
                            if (a.isTvDevice()
                                    && !switchedOnFocus
                                    && id.equals(state.category)
                                    && !id.isEmpty()
                                    && !SourceController.isConfigOrNetdiskSite(site)
                                    && (state.ready || busy)) {
                                state.filtersExpanded = !state.filtersExpanded;
                                inlineFilters.render();
                                updateTabs();
                                wireNavigation();
                                return;
                            }
                            choose(id, true);
                        });
        tabIds.put(button, id);
        button.setOnFocusChangeListener(
                (v, f) -> {
                    styleTab(button);
                    filters.invalidate();
                    if (!f || buildingTabs || applyingFilters || !a.isTvDevice() || !active())
                        return;
                    filters.selection.select(button);
                    scrollCategoryIntoView(button);
                    if (pendingTabSwitch != null) {
                        a.ui.removeCallbacks(pendingTabSwitch);
                        pendingTabSwitch = null;
                    }
                    if (!id.equals(state.category)) {
                        if (a.reduced) {
                            switchedOnFocus = true;
                            v.post(() -> switchedOnFocus = false);
                            choose(id, true);
                        } else {
                            pendingTabSwitch =
                                    () -> {
                                        pendingTabSwitch = null;
                                        if (button.hasFocus()
                                                && active()
                                                && !id.equals(state.category)) {
                                            switchedOnFocus = true;
                                            v.post(() -> switchedOnFocus = false);
                                            choose(id, true);
                                        }
                                    };
                            a.ui.postDelayed(pendingTabSwitch, 110);
                        }
                    }
                });
        addTabView(button);
    }

    void addTabView(TextView button) {
        boolean tv = a.isTvDevice();
        button.setSingleLine(tv);
        button.setMaxLines(tv ? 1 : Integer.MAX_VALUE);
        button.setEllipsize(null);
        button.setMinHeight(a.dp(Math.round(34 * navScale)));
        int padH = a.dp(Math.round(15 * navScale));
        int padV = a.dp(Math.round(8 * navScale));
        button.setPadding(padH, padV, padH, padV);
        filters.addView(button, new android.view.ViewGroup.LayoutParams(-2, -2));
        tabs.add(button);
    }

    void styleTab(TextView b) {
        String id = tabIds.get(b);
        boolean selected = state.category.equals(id);
        styleCategory(b, selected);
        if (selected
                && a.isTvDevice()
                && id != null
                && !id.isEmpty()
                && !SourceController.isConfigOrNetdiskSite(site)) {
            b.setCompoundDrawablePadding(a.dp(5));
            b.setCompoundDrawables(null, null, new FilterChevron(a, state.filtersExpanded), null);
            b.setContentDescription(
                    b.getText() + "，按确认键" + (state.filtersExpanded ? "收起筛选" : "展开筛选"));
        } else {
            b.setCompoundDrawables(null, null, null, null);
            b.setContentDescription(b.getText());
        }
    }

    void styleCategory(TextView b, boolean selected) {
        b.setSelected(selected);
        FocusMotion.style(
                a,
                b,
                false,
                Color.TRANSPARENT,
                Color.TRANSPARENT,
                Math.round(17 * navScale),
                MainActivity.WHITE,
                MainActivity.WHITE,
                false,
                1f);
        b.setBackground(null);
        b.setTextColor(selected ? Color.WHITE : 0xffc8d0df);
        if (selected) {
            filters.selection.select(b);
            scrollCategoryIntoView(b);
        }
    }

    void scrollCategoryIntoView(View tab) {
        if (categoryScroll == null || tab == null) return;
        categoryScroll.post(
                () -> {
                    if (categoryScroll == null || !tab.isAttachedToWindow()) return;
                    int vw = categoryScroll.getWidth();
                    if (vw <= 0) return;
                    int maxScroll = Math.max(0, filters.getWidth() - vw);
                    int desired =
                            tab.getWidth() >= vw
                                    ? tab.getLeft()
                                    : tab.getLeft() - (vw - tab.getWidth()) / 2;
                    int targetX = Math.max(0, Math.min(maxScroll, desired));
                    if (a.reduced) categoryScroll.scrollTo(targetX, 0);
                    else categoryScroll.smoothScrollTo(targetX, 0);
                });
    }

    void collapseFiltersForBrowsing() {
        if (!a.isTvDevice()
                || buildingTabs
                || applyingFilters
                || state == null
                || !state.filtersExpanded) return;
        state.filtersExpanded = false;
        if (inlineFilters != null) inlineFilters.render();
        updateTabs();
        wireNavigation();
        a.body.post(
                () -> {
                    if (!active()) return;
                    wireNavigation();
                    View focused = a.getCurrentFocus();
                    if (focused != null && a.scroll instanceof TvScrollView) {
                        ((TvScrollView) a.scroll).reveal(focused);
                    }
                });
    }

    void updateTabs() {
        for (View v : tabs) {
            TextView b = (TextView) v;
            if (tabIds.get(b) != null) styleTab(b);
            else if ("home-filters".equals(b.getTag())) {
                b.setText(
                        (state.selectedFilters.isEmpty()
                                        ? "筛选"
                                        : "筛选 · " + state.selectedFilters.size())
                                + (a.isTvDevice() ? state.filtersExpanded ? "  ⌃" : "  ⌄" : ""));
                b.setContentDescription((state.filtersExpanded ? "收起" : "展开") + "类型、国家地区、年份筛选");
            } else {
                boolean hidden = false;
                String name = "更多分类";
                int visibleLimit =
                        SourceController.isConfigOrNetdiskSite(site)
                                ? Math.min(16, snapshot.categories.size())
                                : 4;
                for (int i = visibleLimit; i < snapshot.categories.size(); i++)
                    if (snapshot.categories.get(i).id.equals(state.category)) {
                        hidden = true;
                        name = snapshot.categories.get(i).name;
                        break;
                    }
                b.setText(name + "  ⌄");
                if (hidden) styleCategory(b, true);
                else {
                    b.setSelected(false);
                    FocusMotion.style(
                            a,
                            b,
                            b.hasFocus(),
                            0xff24242b,
                            0xff36363e,
                            Math.round(17 * navScale),
                            MainActivity.WHITE,
                            MainActivity.WHITE,
                            true,
                            1.02f);
                }
            }
        }
        if (inlineFilters != null) inlineFilters.render();
        updateFilterToggle();
    }

    View selectedTab() {
        for (View v : tabs) if (tabIds.containsKey(v) && v.isSelected()) return v;
        for (View v : tabs) if ("home-category-more".equals(v.getTag()) && v.isSelected()) return v;
        return tabs.isEmpty() ? source : tabs.get(0);
    }

    void choose(String category, boolean user) {
        if (category.equals(state.category) && (state.ready || busy)) return;
        a.cancelPageRequests();
        request++;
        busy = false;
        state.categoryFailed = false;
        boolean categoryChanged = !state.category.equals(category);
        if (categoryChanged) {
            state.selectedFilters.clear();
            state.activeFilterNote = "";
            state.activeFilterLocalFallback = false;
        }
        if (state.selectedFilters.isEmpty()) {
            state.activeFilterNote = "";
            state.activeFilterLocalFallback = false;
        }
        state.category = category;
        if (a.isTvDevice()) {
            if (category.isEmpty()
                    || SourceController.isConfigOrNetdiskSite(site)
                    || categoryChanged) {
                state.filtersExpanded = false;
            }
        }
        state.ready = false;
        state.videos.clear();
        state.windowStart = 0;
        state.page = 1;
        state.pages = 1;
        pendingFocus = null;
        if (pendingTabSwitch != null) {
            a.ui.removeCallbacks(pendingTabSwitch);
            pendingTabSwitch = null;
        }
        cancelGrid();
        if (a.isTvDevice() && a.scroll != null) {
            int contentTop = content.getTop();
            if (content.isAttachedToWindow()) {
                try {
                    Rect rect = new Rect();
                    a.scroll.offsetDescendantRectToMyCoords(content, rect);
                    contentTop = rect.top;
                } catch (IllegalArgumentException ignored) {
                }
            }
            int minNeeded =
                    Math.max(
                            a.dp(420),
                            Math.max(
                                    a.scroll.getHeight() - a.dp(80),
                                    a.scroll.getScrollY()
                                            + a.scroll.getHeight()
                                            - contentTop
                                            + a.dp(24)));
            if (content.getMinimumHeight() < minNeeded) {
                content.setMinimumHeight(minNeeded);
            }
        }
        clearGrid();
        more.setVisibility(View.GONE);
        updateTabs();
        wireNavigation();
        if (user) {
            View tab = selectedTab();
            if (a.current != null) {
                a.current.focus = String.valueOf(tab.getTag());
            }
            if (!tab.hasFocus()) {
                if (a.isTvDevice() && a.scroll instanceof TvScrollView) {
                    ((TvScrollView) a.scroll).suppressNextReveal = true;
                }
                tab.requestFocus();
            }
            if (a.isTvDevice()) {
                scrollCategoryIntoView(tab);
            } else {
                if (a.current != null) a.current.scroll = 0;
                View bar = categoryScroll != null ? categoryScroll : filters;
                bar.requestRectangleOnScreen(
                        new Rect(0, -a.dp(8), bar.getWidth(), bar.getHeight()), false);
            }
        }
        if (category.isEmpty() && snapshot.recommendationsPending) {
            loadHome();
        } else if (category.isEmpty()) {
            state.videos.addAll(
                    VideoFilters.apply(
                            snapshot.videos, filterDefinitions(), state.selectedFilters));
            state.pages = snapshot.skip.isEmpty() ? 1 : snapshot.pages;
            state.ready = true;
            drawGrid(false);
            if (!user) restoreFocus();
        } else if (state.selectedFilters.isEmpty() && state.categoryCache.containsKey(category)) {
            Cms.Listing cached = state.categoryCache.get(category);
            state.videos.addAll(cached.videos);
            state.pages = Math.max(1, cached.pageCount);
            state.ready = true;
            drawGrid(false);
            if (!user) restoreFocus();
        } else loadCategory(true);
    }

    void loadCategory(boolean first) {
        if (busy || snapshot == null) return;
        String category = state.category.isEmpty() ? snapshot.skip : state.category;
        if (category.isEmpty()) return;
        busy = true;
        state.categoryFailed = false;
        int token = ++request;
        int page = first ? 1 : state.page + 1;
        List<VideoFilters.Definition> definitions = filterDefinitions();
        Map<String, String> selections = new LinkedHashMap<>(state.selectedFilters);
        final VideoFilters.SubCategoryMatch subMatch =
                VideoFilters.resolveMatchingSubCategory(
                        snapshot.categories, category, definitions, selections);
        final String effectiveCategory = subMatch != null ? subMatch.categoryId : category;
        final String satisfiedDim = subMatch != null ? subMatch.satisfiedDimension : null;
        Map<String, String> remoteFilters =
                VideoFilters.remoteValues(definitions, selections, site.supported());
        if (satisfiedDim != null && !site.supported()) {
            remoteFilters.remove(satisfiedDim);
        } else if (satisfiedDim != null) {
            remoteFilters.remove(satisfiedDim);
        }
        final Cms.Listing unfilteredBaseline = first ? state.categoryCache.get(category) : null;
        status.setVisibility(first ? View.VISIBLE : View.GONE);
        status.setText(selections.isEmpty() ? "正在读取分类…" : "正在按筛选条件加载…");
        more.setVisibility(View.GONE);
        DetailRequest timing = new DetailRequest("MovieCategoryTiming");
        a.submitPage(
                () -> {
                    try {
                        timing.dispatched = android.os.SystemClock.elapsedRealtime();
                        SourceEngine engine = a.engine(site);
                        timing.engineReady = android.os.SystemClock.elapsedRealtime();
                        long[] phases = new long[2];
                        String raw =
                                SourceGate.measured(
                                        phases,
                                        () ->
                                                engine.category(
                                                        effectiveCategory, page, remoteFilters));
                        timing.returned = android.os.SystemClock.elapsedRealtime();
                        timing.gateWaitNanos = phases[0];
                        timing.delegateNanos = phases[1];
                        RequestScope.checkCurrent();
                        Cms.Listing list = Cms.listing(raw);
                        clean(list.videos);
                        int received = list.videos.size();
                        boolean remoteIgnored =
                                !selections.isEmpty()
                                        && !remoteFilters.isEmpty()
                                        && ((first
                                                        && subMatch == null
                                                        && unfilteredBaseline != null
                                                        && VideoFilters.isIdenticalListing(
                                                                unfilteredBaseline.videos,
                                                                list.videos))
                                                || !VideoFilters.looksSourceHonored(
                                                        list.videos, definitions, selections));
                        List<Cms.Video> matching =
                                new ArrayList<>(
                                        remoteIgnored
                                                ? VideoFilters.applyAll(
                                                        list.videos,
                                                        definitions,
                                                        selections,
                                                        satisfiedDim)
                                                : VideoFilters.applyExcluding(
                                                        list.videos,
                                                        definitions,
                                                        selections,
                                                        satisfiedDim));
                        int resolvedPage = page;
                        int resolvedPageCount =
                                received == 0 ? page : Math.max(page, list.pageCount);
                        boolean localScan =
                                !selections.isEmpty()
                                        && (remoteIgnored
                                                || VideoFilters.hasLocalExcluding(
                                                        definitions, selections, satisfiedDim));
                        boolean sawMetadata = VideoFilters.hasAnyFilterableMetadata(list.videos);
                        int scanned = 1;
                        int targetMin = Math.max(COLUMNS, Math.min(12, COLUMNS * 2));
                        while (localScan
                                && matching.size() < targetMin
                                && received > 0
                                && resolvedPage < resolvedPageCount
                                && scanned < 6) {
                            int nextPage = resolvedPage + 1;
                            String extraRaw =
                                    engine.category(effectiveCategory, nextPage, remoteFilters);
                            RequestScope.checkCurrent();
                            Cms.Listing extra = Cms.listing(extraRaw);
                            clean(extra.videos);
                            if (extra.videos.isEmpty()) {
                                resolvedPageCount = resolvedPage;
                                break;
                            }
                            if (!sawMetadata) {
                                sawMetadata = VideoFilters.hasAnyFilterableMetadata(extra.videos);
                            }
                            resolvedPage = nextPage;
                            resolvedPageCount = Math.max(resolvedPage, extra.pageCount);
                            matching.addAll(
                                    remoteIgnored
                                            ? VideoFilters.applyAll(
                                                    extra.videos,
                                                    definitions,
                                                    selections,
                                                    satisfiedDim)
                                            : VideoFilters.applyExcluding(
                                                    extra.videos,
                                                    definitions,
                                                    selections,
                                                    satisfiedDim));
                            scanned++;
                        }
                        final int finalPage = resolvedPage;
                        final int finalPageCount = resolvedPageCount;
                        final boolean finalLocalFallback = localScan;
                        final String filterNote;
                        if (selections.isEmpty()) {
                            filterNote = "";
                        } else if (subMatch != null && !localScan) {
                            filterNote = "已切换至「" + subMatch.categoryName + "」子分类筛选";
                        } else if (remoteIgnored && !sawMetadata && matching.isEmpty()) {
                            filterNote = "当前片源未响应筛选且列表缺少年代/地区信息，建议切换分类或全局搜索";
                        } else if (remoteIgnored) {
                            filterNote = "片源未响应服务端筛选，已按影片资料本地筛选（已扫描至第 " + finalPage + " 页）";
                        } else if (localScan && !sawMetadata && matching.isEmpty()) {
                            filterNote = "当前片源列表未返回类型/地区/年份字段，建议切换分类或使用全局搜索";
                        } else if (localScan) {
                            filterNote =
                                    (subMatch != null
                                                    ? "已按「" + subMatch.categoryName + "」与影片资料筛选"
                                                    : "已按影片资料本地筛选")
                                            + "（已扫描至第 "
                                            + finalPage
                                            + " 页）";
                        } else {
                            filterNote = "已按片源筛选条件加载";
                        }
                        timing.parsed = android.os.SystemClock.elapsedRealtime();
                        a.ui.post(
                                () -> {
                                    if (!active() || token != request) return;
                                    busy = false;
                                    int previous = state.videos.size();
                                    boolean focusMore = more.hasFocus();
                                    Set<String> ids = new HashSet<>();
                                    for (Cms.Video v : state.videos) ids.add(v.id);
                                    int added = 0;
                                    for (Cms.Video v : matching)
                                        if (ids.add(v.id)) {
                                            state.videos.add(v);
                                            added++;
                                        }
                                    int oldWindow = state.windowStart;
                                    int focusIndex = previous;
                                    if (added > 0 && previous >= windowEnd()) {
                                        state.windowStart =
                                                (previous / windowSize()) * windowSize();
                                    }
                                    boolean changedWindow = oldWindow != state.windowStart;
                                    int changedPageCount =
                                            (!first && added == 0 && selections.isEmpty())
                                                    ? finalPage
                                                    : finalPageCount;
                                    state.page = finalPage;
                                    state.pages = changedPageCount;
                                    state.activeFilterNote = filterNote;
                                    state.activeFilterLocalFallback = finalLocalFallback;
                                    state.ready = true;
                                    if (first && selections.isEmpty() && !state.videos.isEmpty()) {
                                        Cms.Listing cached = new Cms.Listing();
                                        cached.videos.addAll(state.videos);
                                        cached.pageCount = state.pages;
                                        state.categoryCache.put(category, cached);
                                    }
                                    // Keep focus on the button until the first new card exists,
                                    // so focus never falls back to the category tabs at the top.
                                    pendingFocus =
                                            !first && focusMore ? "home-video:" + focusIndex : null;
                                    drawGrid(!first && !changedWindow);
                                    content.postOnAnimation(timing::ready);
                                    if (first
                                            && a.current != null
                                            && a.current.focus != null
                                            && a.current.focus.startsWith("home-video:"))
                                        restoreFocus();
                                });
                    } catch (Throwable e) {
                        AppLog.w("HomeScreen", "loadCategory failed for " + site.key, e);
                        a.ui.post(
                                () -> {
                                    if (!active() || token != request) return;
                                    busy = false;
                                    state.categoryFailed = true;
                                    status.setVisibility(View.VISIBLE);
                                    status.setText(a.message(e));
                                    more.setText("重新加载");
                                    more.setVisibility(View.VISIBLE);
                                    wireNavigation();
                                });
                    }
                });
    }

    static void clean(List<Cms.Video> videos) {
        Set<String> ids = new HashSet<>();
        Iterator<Cms.Video> it = videos.iterator();
        while (it.hasNext()) {
            Cms.Video v = it.next();
            if (v == null || v.id == null || v.id.trim().isEmpty() || !ids.add(v.id)) {
                it.remove();
            }
        }
    }

    void cancelGrid() {
        gridEpoch++;
        if (pendingGrid != null) {
            a.ui.removeCallbacks(pendingGrid);
            content.removeCallbacks(pendingGrid);
        }
        pendingGrid = null;
    }

    void clearGrid() {
        for (int i = 0; i < content.getChildCount(); i++) {
            android.view.ViewGroup row = (android.view.ViewGroup) content.getChildAt(i);
            for (int j = 0; j < row.getChildCount(); j++)
                if (row.getChildAt(j) instanceof android.view.ViewGroup) {
                    android.view.ViewGroup card = (android.view.ViewGroup) row.getChildAt(j);
                    if (card.getChildCount() > 0) card.getChildAt(0).setTag(null);
                }
        }
        content.removeAllViews();
        rows.clear();
    }

    int windowSize() {
        return Math.max(COLUMNS, (MAX_RETAINED_CARDS / COLUMNS) * COLUMNS);
    }

    int windowEnd() {
        return Math.min(state.videos.size(), state.windowStart + windowSize());
    }

    void showWindow(int start) {
        if (busy || start < 0 || start >= state.videos.size()) return;
        state.windowStart = start;
        pendingFocus = "home-video:" + start;
        if (a.current != null) a.current.focus = pendingFocus;
        drawGrid(false);
        a.smoothHomeScroll(0);
    }

    void drawGrid(boolean append) {
        cancelGrid();
        int existing = state.windowStart;
        for (List<View> row : rows) existing += row.size();
        if (!append) {
            clearGrid();
            existing = state.windowStart;
        }
        updateEarlier();
        if (existing < windowEnd()) a.learnTitles(state.videos.subList(existing, windowEnd()));
        boolean hasFilters = !state.selectedFilters.isEmpty();
        if (!hasFilters) {
            status.setText("这个分类暂无内容，可切换其他分类或使用全局搜索。");
            status.setVisibility(state.videos.isEmpty() ? View.VISIBLE : View.GONE);
        } else if (state.videos.isEmpty()) {
            String note = state.activeFilterNote == null ? "" : state.activeFilterNote.trim();
            status.setText(
                    note.isEmpty()
                            ? "当前已读取的影片没有匹配结果，可继续加载下一页或调整筛选条件。"
                            : note + " · 暂无匹配影片，可点击下方继续筛选或调整条件。");
            status.setVisibility(View.VISIBLE);
        } else {
            String note = state.activeFilterNote == null ? "" : state.activeFilterNote.trim();
            status.setText(
                    note.isEmpty()
                            ? "已筛选出 " + state.videos.size() + " 部影片"
                            : note + " · 已匹配 " + state.videos.size() + " 部影片");
            status.setVisibility(View.VISIBLE);
        }
        // Hiding the focused button would hand focus to the first tab and jump to the top.
        if (pendingFocus == null || !more.hasFocus()) more.setVisibility(View.GONE);
        appendCards(existing, gridEpoch, !append);
    }

    /** Moves focus to the card awaited after "加载更多", once it is laid out. */
    void resolvePendingFocus(boolean finished) {
        if (pendingFocus == null) return;
        View target = a.root.findViewWithTag(pendingFocus);
        if (target == null && finished && !rows.isEmpty()) {
            List<View> last = rows.get(rows.size() - 1);
            target = last.isEmpty() ? null : last.get(0);
        }
        if (target == null) return;
        pendingFocus = null;
        final View card = target;
        if (card.isLaidOut()) card.requestFocus();
        else
            card.addOnLayoutChangeListener(
                    new View.OnLayoutChangeListener() {
                        public void onLayoutChange(
                                View v,
                                int l,
                                int t,
                                int r,
                                int b,
                                int ol,
                                int ot,
                                int or,
                                int ob) {
                            v.removeOnLayoutChangeListener(this);
                            if (active() && v.isAttachedToWindow()) v.requestFocus();
                            if (pendingGrid == null) updateMore();
                        }
                    });
    }

    void updateEarlier() {
        if (state == null) return;
        // Hiding the pressed button before its destination receives focus can select a category.
        if (state.windowStart > 0) earlier.setVisibility(View.VISIBLE);
        else if (!earlier.hasFocus()) earlier.setVisibility(View.GONE);
    }

    /** Keeps "加载更多" hidden during normal browsing (only shown as retry on failure). */
    void updateMore() {
        updateEarlier();
        if (state != null
                && (state.categoryFailed
                        || (!state.ready && "重新加载".equals(String.valueOf(more.getText()))))) {
            more.setText("重新加载");
            more.setVisibility(View.VISIBLE);
            return;
        }
        if (!more.hasFocus()) {
            more.setVisibility(View.GONE);
        }
    }

    /** Shows an explicit "继续筛选下一页" action when active filtering has more server pages. */
    void updateFilterContinueButton() {
        if (state == null || more == null || state.categoryFailed) return;
        if (state.ready
                && !state.selectedFilters.isEmpty()
                && state.page < state.pages
                && state.videos.size() < Math.max(COLUMNS, Math.min(12, COLUMNS * 2))) {
            more.setText("继续筛选下一页");
            more.setVisibility(View.VISIBLE);
        }
    }

    boolean renderedWindowComplete() {
        int rendered = 0;
        for (List<View> row : rows) rendered += row.size();
        return rendered >= windowEnd() - state.windowStart;
    }

    void maybeAutoLoadMore() {
        if (!active()
                || busy
                || state == null
                || !state.ready
                || state.categoryFailed
                || snapshot == null
                || !renderedWindowComplete()) return;
        if (windowEnd() < state.videos.size()) {
            showWindow(state.windowStart + windowSize());
            return;
        }
        if (state.page < state.pages) {
            loadCategory(false);
        }
    }

    void appendCards(int start, int epoch, boolean restore) {
        pendingGrid = null;
        if (!active() || epoch != gridEpoch) return;
        int end = start;
        int batchCount = start == 0 ? Math.max(COLUMNS * 2, 10) : Math.max(COLUMNS, 5);
        long budgetNs = start == 0 ? 12000000L : 5000000L;
        long batchStarted = System.nanoTime();
        for (int index = start; index < windowEnd() && index < start + batchCount; index++) {
            int column = index % COLUMNS;
            LinearLayout row;
            List<View> focusRow;
            if (column == 0) {
                row = a.row();
                row.setGravity(Gravity.TOP);
                row.setClipChildren(false);
                row.setClipToPadding(false);
                row.setPadding(0, a.dp(5), 0, a.dp(18));
                content.addView(row);
                focusRow = new ArrayList<>();
                rows.add(focusRow);
                for (int c = 0; c < COLUMNS; c++) {
                    LinearLayout.LayoutParams cell = new LinearLayout.LayoutParams(0, -2, 1);
                    cell.rightMargin = a.dp(c == COLUMNS - 1 ? 0 : 14);
                    row.addView(new View(a), cell);
                }
            } else {
                row = (LinearLayout) content.getChildAt(content.getChildCount() - 1);
                focusRow = rows.get(rows.size() - 1);
            }
            android.view.ViewGroup.LayoutParams size = row.getChildAt(column).getLayoutParams();
            row.removeViewAt(column);
            View card = card(state.videos.get(index), index);
            row.addView(card, column, size);
            focusRow.add(card);
            end = index + 1;
            if (System.nanoTime() - batchStarted >= budgetNs) break;
        }
        wireNavigation(Math.max(0, (start - state.windowStart) / COLUMNS - 1));
        resolvePendingFocus(false);
        if (end < windowEnd()) {
            final int next = end;
            pendingGrid = () -> appendCards(next, epoch, restore);
            Runnable nextBatch = pendingGrid;
            content.postOnAnimation(
                    () -> {
                        if (active() && epoch == gridEpoch) a.ui.post(nextBatch);
                    });
        } else {
            resolvePendingFocus(true);
            updateMore();
            updateFilterContinueButton();
            wireNavigation(Math.max(0, rows.size() - 1));
            if (restore
                    && a.current != null
                    && a.current.focus != null
                    && a.current.focus.startsWith("home-video:")) restoreFocus();
        }
    }

    View card(Cms.Video video, int index) {
        LinearLayout card = a.vertical();
        card.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(4));
        card.setGravity(Gravity.CENTER_HORIZONTAL);
        card.setClipChildren(false);
        ImageView art = new AmbientPoster();
        if (a.isTvDevice()) TvV17PosterCard.artwork(a, art);
        else {
            art.setScaleType(ImageView.ScaleType.CENTER_CROP);
            art.setBackground(a.bg(0xff25252d, 10));
            art.setClipToOutline(true);
        }
        boolean showDoubanBadge = !SourceController.isConfigOrNetdiskActionCard(site, video);
        FrameLayout artWrap =
                TvV17PosterCard.wrapArtworkWithDoubanBadge(a, art, video, showDoubanBadge);
        card.addView(
                artWrap,
                new LinearLayout.LayoutParams(a.dp(posterWidth), a.dp(posterWidth * 1.5f)));
        a.poster(video.poster, art);
        TextView title = a.text(video.title, 13, 0xffc8c8d0);
        single(title);
        title.setPadding(a.dp(2), a.dp(7), a.dp(2), 0);
        card.addView(title, new LinearLayout.LayoutParams(-1, a.dp(27)));
        focusable(card, "home-video:" + index);
        if (a.isTvDevice()) TvFocusFrame.attachCard(card, "home-library-grid");
        outline(card, false, 13, Color.TRANSPARENT);
        card.setContentDescription(video.title);
        card.setOnClickListener(v -> a.openListing(site, video));
        card.setOnFocusChangeListener(
                (v, f) -> {
                    if (a.isTvDevice()) TvV17PosterCard.focus(a, card, title, f);
                    else {
                        outline(card, f, 13, Color.TRANSPARENT);
                        title.setTextColor(f ? Color.WHITE : 0xffc8c8d0);
                    }
                    if (f && ambient != null) ambient.follow(art);
                    if (f) {
                        collapseFiltersForBrowsing();
                        int localRow = (index - state.windowStart) / Math.max(1, COLUMNS);
                        if (localRow >= Math.max(1, rows.size() - 2)) {
                            maybeAutoLoadMore();
                        }
                        if (!(a.scroll instanceof TvScrollView)) {
                            v.requestRectangleOnScreen(
                                    new Rect(0, -a.dp(8), v.getWidth(), v.getHeight() + a.dp(10)),
                                    false);
                        }
                        if (!a.reduced) {
                            v.postDelayed(
                                    () -> {
                                        if (v.hasFocus() && active()) {
                                            SourceController.prefetchDetail(a, site, video);
                                        }
                                    },
                                    360);
                        }
                    }
                });
        if (index == 0
                && ambient != null
                && (ambient.wanted == null || !ambient.wanted.isAttachedToWindow()))
            ambient.follow(art);
        return card;
    }

    void outline(View view, boolean focused, int radius, int color) {
        FocusMotion.style(
                a,
                view,
                focused,
                color,
                color,
                radius,
                MainActivity.WHITE,
                MainActivity.WHITE,
                true,
                view instanceof TextView ? 1.02f : 1.035f);
    }

    void single(TextView text) {
        text.setSingleLine(true);
        text.setEllipsize(TextUtils.TruncateAt.END);
    }

    void focusable(View view, String tag) {
        view.setTag(tag);
        view.setId(View.generateViewId());
        view.setFocusable(true);
        view.setFocusableInTouchMode(true);
        view.setClickable(true);
        a.pressFeedback(view);
    }

    TextView pill(String label, String tag, Runnable action) {
        TextView b = a.text(label, 12f * navScale, MainActivity.WHITE);
        single(b);
        b.setGravity(Gravity.CENTER);
        b.setIncludeFontPadding(false);
        int padH = a.dp(Math.round(15 * navScale));
        int radius = Math.round(18 * navScale);
        b.setPadding(padH, 0, padH, 0);
        focusable(b, tag);
        b.setBackground(a.bg(0xff24242b, radius));
        b.setOnClickListener(v -> action.run());
        b.setOnFocusChangeListener((v, f) -> outline(b, f, radius, 0xff24242b));
        return b;
    }

    void horizontal(List<View> line) {
        for (int i = 0; i < line.size(); i++) {
            line.get(i).setNextFocusLeftId(line.get(Math.max(0, i - 1)).getId());
            line.get(i).setNextFocusRightId(line.get(Math.min(line.size() - 1, i + 1)).getId());
        }
    }

    /** A visible target for three-Up and return restoration. */
    View topTarget() {
        String[] tags =
                new String[] {
                    "home-curated-hero-play",
                    "home-history:0",
                    "home-curated-drama:0",
                    "home-tab:0",
                    "source-switcher"
                };
        for (String tag : tags) {
            View target = a.root.findViewWithTag(tag);
            if (target != null && target.isShown() && target.isFocusable() && target.isEnabled())
                return target;
        }
        return null;
    }

    void wireNavigation() {
        wireNavigation(0);
    }

    void wireNavigation(int firstRow) {
        View nav = a.root.findViewWithTag("nav-home");
        if (nav != null && nav.getId() == View.NO_ID) nav.setId(View.generateViewId());
        boolean tvLeftDock = a.homeDock != null && a.homeDock.tvLeft;
        boolean topDockActive = !tvLeftDock && a.useTopDock() && a.homeDock != null;
        boolean stackedHistory = !tvLeftDock && a.useBottomDock();

        int firstAfterHeroId =
                !curatedDramaCards.isEmpty()
                        ? curatedDramaCards.get(0).getId()
                        : !curatedMovieCards.isEmpty()
                                ? curatedMovieCards.get(0).getId()
                                : !historyCards.isEmpty()
                                        ? historyCards.get(0).getId()
                                        : source.getId();
        int firstAfterDramasId =
                !curatedMovieCards.isEmpty()
                        ? curatedMovieCards.get(0).getId()
                        : !historyCards.isEmpty() ? historyCards.get(0).getId() : source.getId();
        int firstAfterMoviesId =
                !historyCards.isEmpty() ? historyCards.get(0).getId() : source.getId();

        if (curatedHeroBtn != null) {
            curatedHeroBtn.setNextFocusUpId(
                    topDockActive ? a.homeDock.items[0].getId() : curatedHeroBtn.getId());
            curatedHeroBtn.setNextFocusDownId(firstAfterHeroId);
            if (tvLeftDock && curatedHeroIndex <= 0) {
                a.homeDock.leftEdge(curatedHeroBtn, false);
            } else {
                curatedHeroBtn.setNextFocusLeftId(View.NO_ID);
            }
            curatedHeroBtn.setNextFocusRightId(View.NO_ID);
        }
        horizontal(curatedDramaCards);
        for (int i = 0; i < curatedDramaCards.size(); i++) {
            View c = curatedDramaCards.get(i);
            c.setNextFocusUpId(
                    curatedHeroBtn != null
                            ? curatedHeroBtn.getId()
                            : (topDockActive
                                    ? a.homeDock.items[Math.min(i, a.homeDock.items.length - 1)]
                                            .getId()
                                    : c.getId()));
            c.setNextFocusDownId(
                    !curatedMovieCards.isEmpty()
                            ? curatedMovieCards
                                    .get(Math.min(i, curatedMovieCards.size() - 1))
                                    .getId()
                            : firstAfterDramasId);
        }
        if (tvLeftDock && !curatedDramaCards.isEmpty()) {
            a.homeDock.leftEdge(curatedDramaCards.get(0), false);
        }
        horizontal(curatedMovieCards);
        for (int i = 0; i < curatedMovieCards.size(); i++) {
            View c = curatedMovieCards.get(i);
            c.setNextFocusUpId(
                    !curatedDramaCards.isEmpty()
                            ? curatedDramaCards
                                    .get(Math.min(i, curatedDramaCards.size() - 1))
                                    .getId()
                            : curatedHeroBtn != null
                                    ? curatedHeroBtn.getId()
                                    : (topDockActive
                                            ? a.homeDock
                                                    .items[Math.min(i, a.homeDock.items.length - 1)]
                                                    .getId()
                                            : c.getId()));
            c.setNextFocusDownId(firstAfterMoviesId);
        }
        if (tvLeftDock && !curatedMovieCards.isEmpty()) {
            a.homeDock.leftEdge(curatedMovieCards.get(0), false);
        }

        int aboveHistoryId =
                !curatedMovieCards.isEmpty()
                        ? curatedMovieCards.get(0).getId()
                        : !curatedDramaCards.isEmpty()
                                ? curatedDramaCards.get(0).getId()
                                : curatedHeroBtn != null ? curatedHeroBtn.getId() : View.NO_ID;

        horizontal(historyCards);
        for (int i = 0; i < historyCards.size(); i++) {
            View card = historyCards.get(i);
            card.setNextFocusUpId(
                    stackedHistory
                            ? (i == 0 ? allHistory : historyCards.get(i - 1)).getId()
                            : aboveHistoryId != View.NO_ID
                                    ? aboveHistoryId
                                    : topDockActive
                                            ? a.homeDock
                                                    .items[Math.min(i, a.homeDock.items.length - 1)]
                                                    .getId()
                                            : card.getId());
            card.setNextFocusDownId(
                    stackedHistory && i + 1 < historyCards.size()
                            ? historyCards.get(i + 1).getId()
                            : source.getId());
            if (stackedHistory) {
                card.setNextFocusLeftId(card.getId());
                card.setNextFocusRightId(card.getId());
            }
        }
        if (!historyCards.isEmpty()) {
            View lastHistory = historyCards.get(historyCards.size() - 1);
            if (!stackedHistory) lastHistory.setNextFocusRightId(allHistory.getId());
            allHistory.setNextFocusLeftId(
                    stackedHistory ? allHistory.getId() : lastHistory.getId());
            allHistory.setNextFocusDownId(
                    stackedHistory ? historyCards.get(0).getId() : source.getId());
            if (aboveHistoryId != View.NO_ID) {
                allHistory.setNextFocusUpId(aboveHistoryId);
            } else if (topDockActive) {
                allHistory.setNextFocusUpId(a.homeDock.items[a.homeDock.items.length - 1].getId());
            }
        }
        int sourceUpId =
                historyCards.isEmpty()
                        ? (aboveHistoryId != View.NO_ID
                                ? aboveHistoryId
                                : (topDockActive ? a.homeDock.items[0].getId() : source.getId()))
                        : historyCards.get(stackedHistory ? historyCards.size() - 1 : 0).getId();
        source.setNextFocusUpId(sourceUpId);
        source.setNextFocusDownId(selectedTab().getId());
        boolean filterToggleShown = filterToggle != null && filterToggle.isShown();
        if (filterToggleShown) {
            source.setNextFocusRightId(filterToggle.getId());
            filterToggle.setNextFocusLeftId(source.getId());
            filterToggle.setNextFocusRightId(filterToggle.getId());
            filterToggle.setNextFocusUpId(sourceUpId);
        } else {
            source.setNextFocusRightId(source.getId());
        }
        int contentDownId =
                earlier.isShown()
                        ? earlier.getId()
                        : rows.isEmpty()
                                ? (more.isShown() ? more.getId() : -1)
                                : rows.get(0).get(0).getId();
        boolean inlineExpanded = inlineFilters != null && inlineFilters.expanded();
        boolean inlineSummary = inlineFilters != null && inlineFilters.summaryShown();
        View firstFilterChip = inlineExpanded ? inlineFilters.entryChip(0) : null;
        if (filterToggleShown) {
            filterToggle.setNextFocusDownId(
                    firstFilterChip != null ? firstFilterChip.getId() : selectedTab().getId());
        }
        for (int r = 0; r < filters.lines.size(); r++) {
            List<View> line = filters.lines.get(r);
            horizontal(line);
            if (!line.isEmpty() && r + 1 < filters.lines.size()) {
                List<View> nextLine = filters.lines.get(r + 1);
                if (!nextLine.isEmpty()) {
                    line.get(line.size() - 1).setNextFocusRightId(nextLine.get(0).getId());
                }
            }
            if (!line.isEmpty() && r > 0) {
                List<View> prevLine = filters.lines.get(r - 1);
                if (!prevLine.isEmpty()) {
                    line.get(0).setNextFocusLeftId(prevLine.get(prevLine.size() - 1).getId());
                }
            }
            for (View tab : line) {
                tab.setNextFocusUpId(
                        r == 0
                                ? source.getId()
                                : filters.nearest(filters.lines.get(r - 1), tab).getId());
                int downId =
                        firstFilterChip != null
                                ? firstFilterChip.getId()
                                : inlineSummary
                                        ? inlineFilters.expandButton.getId()
                                        : contentDownId != -1 ? contentDownId : tab.getId();
                if (r + 1 < filters.lines.size()) {
                    View below = filters.nearest(filters.lines.get(r + 1), tab);
                    boolean overlaps =
                            below != null
                                    && below.getRight() > tab.getLeft()
                                    && below.getLeft() < tab.getRight();
                    if (overlaps) {
                        downId = below.getId();
                    }
                }
                tab.setNextFocusDownId(downId);
            }
        }
        if (inlineExpanded) {
            for (int r = 0; r < inlineFilters.rows.size(); r++) {
                List<View> line = inlineFilters.rows.get(r);
                horizontal(line);
                for (View option : line) {
                    View filterButton = filters.findViewWithTag("home-filters");
                    option.setNextFocusUpId(
                            r == 0
                                    ? (filterButton == null ? selectedTab() : filterButton).getId()
                                    : inlineFilters
                                            .nearest(inlineFilters.rows.get(r - 1), option)
                                            .getId());
                    option.setNextFocusDownId(
                            r + 1 < inlineFilters.rows.size()
                                    ? inlineFilters
                                            .nearest(inlineFilters.rows.get(r + 1), option)
                                            .getId()
                                    : !rows.isEmpty() && !earlier.isShown()
                                            ? inlineFilters.nearest(rows.get(0), option).getId()
                                            : contentDownId == -1 ? option.getId() : contentDownId);
                }
            }
        } else if (inlineSummary) {
            List<View> actions =
                    Arrays.asList(inlineFilters.expandButton, inlineFilters.resetButton);
            horizontal(actions);
            int summaryUpId = selectedTab().getId();
            inlineFilters.expandButton.setNextFocusUpId(summaryUpId);
            inlineFilters.expandButton.setNextFocusDownId(
                    contentDownId != -1 ? contentDownId : inlineFilters.expandButton.getId());
            inlineFilters.resetButton.setNextFocusUpId(summaryUpId);
            inlineFilters.resetButton.setNextFocusDownId(
                    contentDownId != -1 ? contentDownId : inlineFilters.resetButton.getId());
        }
        int lastInlineRow = inlineExpanded ? inlineFilters.rows.size() - 1 : -1;
        for (int r = Math.max(0, firstRow); r < rows.size(); r++) {
            List<View> row = rows.get(r);
            horizontal(row);
            for (int c = 0; c < row.size(); c++) {
                View card = row.get(c);
                card.setNextFocusUpId(
                        r == 0
                                ? (earlier.isShown()
                                        ? earlier.getId()
                                        : inlineExpanded
                                                ? inlineFilters
                                                        .nearest(
                                                                inlineFilters.rows.get(
                                                                        lastInlineRow),
                                                                card)
                                                        .getId()
                                                : inlineSummary
                                                        ? inlineFilters.expandButton.getId()
                                                        : selectedTab().getId())
                                : rows.get(r - 1)
                                        .get(Math.min(c, rows.get(r - 1).size() - 1))
                                        .getId());
                card.setNextFocusDownId(
                        r + 1 < rows.size()
                                ? rows.get(r + 1)
                                        .get(Math.min(c, rows.get(r + 1).size() - 1))
                                        .getId()
                                : more.isShown() ? more.getId() : card.getId());
            }
        }
        if (tvLeftDock) {
            a.homeDock.leftEdge(source, false);
            if (!historyCards.isEmpty()) a.homeDock.leftEdge(historyCards.get(0), false);
            for (List<View> line : filters.lines)
                if (!line.isEmpty()) a.homeDock.leftEdge(line.get(0), false);
            if (inlineExpanded) {
                for (List<View> line : inlineFilters.rows)
                    if (!line.isEmpty()) a.homeDock.leftEdge(line.get(0), false);
            } else if (inlineSummary) a.homeDock.leftEdge(inlineFilters.expandButton, false);
            for (List<View> row : rows) if (!row.isEmpty()) a.homeDock.leftEdge(row.get(0), false);
            a.homeDock.leftEdge(earlier, false);
            a.homeDock.leftEdge(more, false);
        }
        int aboveGridId =
                inlineExpanded
                        ? inlineFilters.rows.get(lastInlineRow).get(0).getId()
                        : inlineSummary
                                ? inlineFilters.expandButton.getId()
                                : selectedTab().getId();
        earlier.setNextFocusUpId(aboveGridId);
        earlier.setNextFocusDownId(rows.isEmpty() ? more.getId() : rows.get(0).get(0).getId());
        more.setNextFocusUpId(
                rows.isEmpty() ? aboveGridId : rows.get(rows.size() - 1).get(0).getId());
    }

    static boolean navigationKey(MainActivity a, android.view.KeyEvent event) {
        int key = event.getKeyCode();
        if (key != android.view.KeyEvent.KEYCODE_DPAD_UP
                && key != android.view.KeyEvent.KEYCODE_DPAD_DOWN
                && key != android.view.KeyEvent.KEYCODE_DPAD_LEFT
                && key != android.view.KeyEvent.KEYCODE_DPAD_RIGHT) return false;
        View focus = a.getCurrentFocus();
        if (focus == null || a.scroll == null) return false;
        android.view.ViewParent parent = focus.getParent();
        while (parent != null && parent != a.scroll) parent = parent.getParent();
        if (parent != a.scroll) return false;
        int id =
                key == android.view.KeyEvent.KEYCODE_DPAD_UP
                        ? focus.getNextFocusUpId()
                        : key == android.view.KeyEvent.KEYCODE_DPAD_DOWN
                                ? focus.getNextFocusDownId()
                                : key == android.view.KeyEvent.KEYCODE_DPAD_LEFT
                                        ? focus.getNextFocusLeftId()
                                        : focus.getNextFocusRightId();
        if (id == View.NO_ID) return false;
        if (event.getAction() != android.view.KeyEvent.ACTION_DOWN) return true;
        View target = a.root.findViewById(id);
        if (target == null || !target.isShown() || !target.isFocusable()) return false;
        if (key == android.view.KeyEvent.KEYCODE_DPAD_DOWN
                && target == focus
                && a.current != null
                && a.current.retainedHome != null) {
            a.current.retainedHome.maybeAutoLoadMore();
        }
        target.requestFocus();
        String tag = String.valueOf(target.getTag());
        boolean hasCuratedTop =
                a.root != null && a.root.findViewWithTag("home-curated-hero-play") != null;
        if (key == android.view.KeyEvent.KEYCODE_DPAD_UP
                && (tag.equals("home-curated-hero-play")
                        || (!hasCuratedTop
                                && (tag.startsWith("home-history:")
                                        || tag.equals("home-history-all")))
                        || (target == focus && a.scroll.getScrollY() < a.dp(120)))) {
            a.smoothHomeScroll(0);
        } else if (!(a.scroll instanceof TvScrollView))
            target.requestRectangleOnScreen(
                    new Rect(0, -a.dp(12), target.getWidth(), target.getHeight() + a.dp(12)),
                    false);
        return true;
    }

    void styleSource(boolean focused) {
        FocusMotion.style(
                a,
                source,
                focused,
                0x66344352,
                0xff344452,
                // Fully rounded capsule matching the 34dp pill height.
                17,
                0xffd7e2ed,
                Color.WHITE,
                true,
                1.02f);
    }

    final class AmbientPoster extends ImageView {
        AmbientPoster() {
            super(a);
        }

        @Override
        public void setImageBitmap(android.graphics.Bitmap bitmap) {
            super.setImageBitmap(bitmap);
            if (ambient != null) ambient.posterReady(this);
        }
    }

    static final class SourceChevron extends android.graphics.drawable.Drawable {
        final android.graphics.Paint paint = new android.graphics.Paint(3);
        final MainActivity a;

        SourceChevron(MainActivity a) {
            this.a = a;
            setBounds(0, 0, a.dp(10), a.dp(10));
        }

        public void draw(android.graphics.Canvas canvas) {
            android.graphics.Rect b = getBounds();
            paint.setColor(0xffd7e2ed);
            paint.setStyle(android.graphics.Paint.Style.STROKE);
            paint.setStrokeWidth(a.dp(1.4f));
            paint.setStrokeCap(android.graphics.Paint.Cap.ROUND);
            paint.setStrokeJoin(android.graphics.Paint.Join.ROUND);
            android.graphics.Path path = new android.graphics.Path();
            path.moveTo(b.left + b.width() * .15f, b.top + b.height() * .35f);
            path.lineTo(b.exactCenterX(), b.top + b.height() * .65f);
            path.lineTo(b.left + b.width() * .85f, b.top + b.height() * .35f);
            canvas.drawPath(path, paint);
        }

        public void setAlpha(int value) {
            paint.setAlpha(value);
        }

        public void setColorFilter(android.graphics.ColorFilter value) {
            paint.setColorFilter(value);
        }

        public int getOpacity() {
            return android.graphics.PixelFormat.TRANSLUCENT;
        }
    }

    static final class FilterChevron extends android.graphics.drawable.Drawable {
        final android.graphics.Paint paint = new android.graphics.Paint(3);
        final MainActivity a;
        final boolean expanded;

        FilterChevron(MainActivity a, boolean expanded) {
            this.a = a;
            this.expanded = expanded;
            setBounds(0, 0, a.dp(9), a.dp(9));
        }

        public void draw(android.graphics.Canvas canvas) {
            android.graphics.Rect b = getBounds();
            paint.setColor(0xffe8eef6);
            paint.setStyle(android.graphics.Paint.Style.STROKE);
            paint.setStrokeWidth(a.dp(1.35f));
            paint.setStrokeCap(android.graphics.Paint.Cap.ROUND);
            paint.setStrokeJoin(android.graphics.Paint.Join.ROUND);
            android.graphics.Path path = new android.graphics.Path();
            float yEdge = b.top + b.height() * (expanded ? .66f : .34f);
            float yTip = b.top + b.height() * (expanded ? .34f : .66f);
            path.moveTo(b.left + b.width() * .15f, yEdge);
            path.lineTo(b.exactCenterX(), yTip);
            path.lineTo(b.left + b.width() * .85f, yEdge);
            canvas.drawPath(path, paint);
        }

        public void setAlpha(int value) {
            paint.setAlpha(value);
        }

        public void setColorFilter(android.graphics.ColorFilter value) {
            paint.setColorFilter(value);
        }

        public int getOpacity() {
            return android.graphics.PixelFormat.TRANSLUCENT;
        }
    }

    /** Late home data must not pull focus back once the user has moved it (dock, account panel). */
    void restoreFocus() {
        a.ui.post(
                () -> {
                    if (!active() || a.current == null) return;
                    View saved =
                            a.current.focus == null
                                    ? null
                                    : a.root.findViewWithTag(a.current.focus);
                    View now = a.getCurrentFocus();
                    if (saved != null
                            && saved.isShown()
                            && saved.isFocusable()
                            && (now == null || now == a.autoFocus || now == saved)) {
                        saved.requestFocus();
                        a.autoFocus = saved;
                        a.scroll.scrollTo(0, a.current.scroll);
                    }
                });
    }
}
