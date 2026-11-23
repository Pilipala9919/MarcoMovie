package com.pilipala.marcomovie;

import android.graphics.*;
import android.graphics.drawable.GradientDrawable;
import android.view.*;
import android.widget.*;

/** Home navigation bar. TV defaults to a scroll-shrinking immersive top bar with permanent logo. */
final class HomeDock {
    static final int ICON_HOME = 0;
    static final int ICON_SEARCH = 1;
    static final int ICON_LIVE = 2;
    static final int ICON_FAVORITE = 3;
    static final int ICON_ACCOUNT = 4;
    static final int ICON_CAST = 5;
    static final int ICON_SETTINGS = 6;
    static final int ICON_HISTORY = 8;

    private static android.view.animation.DecelerateInterpolator topDecelCache;

    private static android.view.animation.DecelerateInterpolator topDecel() {
        if (topDecelCache == null) {
            topDecelCache = new android.view.animation.DecelerateInterpolator();
        }
        return topDecelCache;
    }

    final MainActivity a;
    final LinearLayout rail;
    TextView brandText;
    View edgeShade;
    android.graphics.drawable.Drawable edgeShadeCollapsed, edgeShadeExpanded;
    View topScrim;
    LinearLayout topBrandPill;
    final View[] items;
    final GlassSelection selection;
    final String[] labels;
    final String[] keys;
    final int[] iconKinds;

    final boolean bottomMode, topMode, horizontal, tvLeft, tvTopLabeled;
    final TvV17Navigation navigation = new TvV17Navigation();
    boolean expanded;
    private float lastScrollProgress = -1f;
    private boolean topFocused;
    private java.lang.ref.WeakReference<View> menuReturnRef;
    final float navScale, fitScale;
    final int crossDp, mainDp, cellDp;
    final int sideMarginDp, topMarginDp, topSafeInsetDp;
    private float runtimeOverflowScale = 1f;

    static final class AdaptiveTopMetrics {
        final float fitScale;
        final int sideMarginDp;
        final int topMarginDp;
        final int crossDp;
        final int cellDp;
        final int topSafeInsetDp;

        AdaptiveTopMetrics(
                float fitScale,
                int sideMarginDp,
                int topMarginDp,
                int crossDp,
                int cellDp,
                int topSafeInsetDp) {
            this.fitScale = fitScale;
            this.sideMarginDp = sideMarginDp;
            this.topMarginDp = topMarginDp;
            this.crossDp = crossDp;
            this.cellDp = cellDp;
            this.topSafeInsetDp = topSafeInsetDp;
        }
    }

    /**
     * Pure-JVM adaptive top navigation bar sizing across real TV resolutions (720p / 1080p / 4K /
     * ultrawide), OEM DPI scales, system font scales, and user navigation scale preferences.
     * Guarantees the left brand mark and right 8-item capsule never collide or clip.
     */
    static AdaptiveTopMetrics computeAdaptiveTopMetrics(
            int windowWidthPx,
            int windowHeightPx,
            float density,
            float fontScale,
            float requestedNavScale,
            int itemCount) {
        float safeDensity = Math.max(0.5f, density);
        float widthDp = Math.max(360f, windowWidthPx / safeDensity);
        float heightDp = Math.max(240f, windowHeightPx / safeDensity);
        int count = Math.max(1, itemCount);
        float safeReq = Math.max(0.75f, Math.min(1.25f, requestedNavScale));
        float safeFont = Math.max(0.85f, Math.min(1.35f, fontScale));

        // Proportional viewport factor against standard 960x540 TV logical canvas.
        float screenFactor = Math.min(widthDp / 960f, heightDp / 540f);
        float clampedScreen = Math.max(0.74f, Math.min(1.18f, screenFactor));
        int sideMargin = Math.max(20, Math.min(52, Math.round(widthDp * 0.045f)));
        int topMargin = Math.max(10, Math.min(22, Math.round(heightDp * 0.029f)));

        // Conservative width budget at scale=1.0: brand (~142dp) + 8 labeled pills (~604dp) + gap.
        float brandAtOneDp = 28f + 9f + 105f * Math.max(1f, safeFont * 0.96f);
        float itemAtOneDp = 20f + 18f + 4.5f + 27f * Math.max(1f, safeFont * 0.96f) + 4f;
        float railAtOneDp = 16f + count * itemAtOneDp;
        float minGapDp = Math.max(18f, Math.min(32f, widthDp * 0.025f));
        float availableWidthDp = Math.max(220f, widthDp - sideMargin * 2f - minGapDp);
        float maxScaleByWidth = availableWidthDp / (brandAtOneDp + railAtOneDp);

        // Keep top bar height sleek (<= 10.5% of viewport height).
        float maxScaleByHeight = (heightDp * 0.105f) / 46f;

        float desired = safeReq * clampedScreen;
        float fit = Math.min(desired, Math.min(maxScaleByWidth, maxScaleByHeight));
        fit = Math.max(0.60f, Math.min(1.22f, fit));

        int cross = Math.max(32, Math.round(46f * fit));
        int cell = Math.max(26, Math.round(38f * fit));
        int safeTopInset = topMargin + cross + Math.max(20, Math.round(22f * fit));
        return new AdaptiveTopMetrics(fit, sideMargin, topMargin, cross, cell, safeTopInset);
    }

    int topSafeInsetPx() {
        if (tvTopLabeled) return a.dp(topSafeInsetDp);
        if (topMode) return a.dp(crossDp + 34);
        return a.dp(24);
    }

    int leftSafeInsetPx() {
        if (tvLeft) return a.dp(Math.max(84, crossDp + 34));
        return a.dp(sideMarginDp);
    }

    int rightSafeInsetPx() {
        return a.dp(sideMarginDp);
    }

    static String[] tvNavLabels() {
        return new String[] {"首页", "搜索", "历史", "直播", "我的", "网盘", "投屏", "设置"};
    }

    static String[] tvNavKeys() {
        return new String[] {
            "nav-home",
            "nav-search",
            "nav-history",
            "nav-live",
            "nav-favorites",
            "nav-accounts",
            "nav-cast",
            "nav-settings"
        };
    }

    static float computeTopShrinkProgress(int scrollY, int rangePx) {
        if (scrollY <= 0 || rangePx <= 0) return 0f;
        float raw = scrollY / (float) rangePx;
        return Math.max(0f, Math.min(1f, raw));
    }

    static float computeTopScrimAlpha(float progress) {
        float p = Math.max(0f, Math.min(1f, progress));
        float smooth = p * p * (3f - 2f * p);
        return 0.18f + 0.76f * smooth;
    }

    HomeDock(MainActivity host) {
        a = host;
        tvLeft = a.useLeftDock();
        bottomMode = !tvLeft && a.useBottomDock();
        topMode = !tvLeft && a.useTopDock();
        horizontal = bottomMode || topMode;
        tvTopLabeled = topMode && a.isTvDevice();
        boolean tvNav = tvLeft || tvTopLabeled;
        labels = tvNav ? tvNavLabels() : new String[] {"首页", "搜索", "直播", "收藏", "网盘", "投屏", "设置"};
        keys =
                tvNav
                        ? tvNavKeys()
                        : new String[] {
                            "nav-home",
                            "nav-search",
                            "nav-live",
                            "nav-favorites",
                            "nav-accounts",
                            "nav-cast",
                            "nav-settings"
                        };
        iconKinds =
                tvNav
                        ? new int[] {
                            ICON_HOME,
                            ICON_SEARCH,
                            ICON_HISTORY,
                            ICON_LIVE,
                            ICON_FAVORITE,
                            ICON_ACCOUNT,
                            ICON_CAST,
                            ICON_SETTINGS
                        }
                        : new int[] {
                            ICON_HOME,
                            ICON_SEARCH,
                            ICON_LIVE,
                            ICON_FAVORITE,
                            ICON_ACCOUNT,
                            ICON_CAST,
                            ICON_SETTINGS
                        };
        items = new View[labels.length];
        navScale = Prefs.clampNavScale(a.prefs.getInt(Prefs.NAV_SCALE_PERCENT, 100)) / 100f;
        int rawMainBase =
                tvTopLabeled
                        ? 630
                        : (a.isTvDevice() ? (horizontal ? 374 : 368) : (horizontal ? 342 : 338));
        android.util.DisplayMetrics dm = a.getResources().getDisplayMetrics();
        float density = Math.max(0.5f, dm.density);
        float fontScale =
                a.getResources().getConfiguration() != null
                        ? a.getResources().getConfiguration().fontScale
                        : 1f;
        if (tvTopLabeled) {
            AdaptiveTopMetrics m =
                    computeAdaptiveTopMetrics(
                            a.windowWidth(),
                            a.windowHeight(),
                            density,
                            fontScale,
                            navScale,
                            items.length);
            fitScale = m.fitScale;
            sideMarginDp = m.sideMarginDp;
            topMarginDp = m.topMarginDp;
            crossDp = m.crossDp;
            cellDp = m.cellDp;
            topSafeInsetDp = m.topSafeInsetDp;
            mainDp = Math.round(rawMainBase * fitScale);
        } else {
            int windowMainDp =
                    Math.max(
                            260,
                            Math.round((horizontal ? a.windowWidth() : a.windowHeight()) / density)
                                    - 32);
            fitScale =
                    tvLeft
                            ? TvRailMetrics.fit(
                                    navScale,
                                    Math.max(1, a.windowHeight() - a.dp(32)),
                                    density,
                                    items.length)
                            : Math.round(rawMainBase * navScale) > windowMainDp
                                    ? Math.min(navScale, windowMainDp / (float) rawMainBase)
                                    : navScale;
            sideMarginDp = a.isTvDevice() ? 44 : 18;
            topMarginDp = 16;
            cellDp = Math.round((a.isTvDevice() ? 42 : 38) * fitScale);
            crossDp = Math.round((a.isTvDevice() ? 56 : 50) * fitScale);
            topSafeInsetDp = topMode ? crossDp + 34 : 24;
            mainDp = Math.round(rawMainBase * fitScale);
        }
        rail =
                new LinearLayout(a) {
                    @Override
                    protected void dispatchDraw(Canvas canvas) {
                        selection.draw(canvas);
                        super.dispatchDraw(canvas);
                    }

                    @Override
                    protected void onLayout(boolean changed, int l, int t, int r, int b) {
                        super.onLayout(changed, l, t, r, b);
                        if (tvTopLabeled) {
                            setPivotX(getWidth());
                            setPivotY(0f);
                            reconcileTopOverflow();
                        }
                        selection.refresh();
                    }
                };
        rail.setOrientation(horizontal ? LinearLayout.HORIZONTAL : LinearLayout.VERTICAL);
        selection =
                new GlassSelection(
                        a,
                        rail,
                        (tvTopLabeled ? 18f : 10.5f) * fitScale,
                        true,
                        tvLeft || tvTopLabeled);
        rail.setTag("home-dock");
        rail.setGravity(Gravity.CENTER);
        rail.setClipChildren(false);
        rail.setClipToPadding(false);
        rail.setPadding(
                a.dp(Math.round((tvTopLabeled ? 7 : (horizontal ? 10 : 6)) * fitScale)),
                a.dp(Math.round((tvTopLabeled ? 4 : (horizontal ? 6 : 8)) * fitScale)),
                a.dp(Math.round((tvTopLabeled ? 7 : (horizontal ? 10 : 6)) * fitScale)),
                a.dp(Math.round((tvTopLabeled ? 4 : (horizontal ? 6 : 8)) * fitScale)));
        if (tvTopLabeled) {
            topScrim = new View(a);
            topScrim.setTag("home-top-scrim");
            topScrim.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
            GradientDrawable scrimBg =
                    new GradientDrawable(
                            GradientDrawable.Orientation.TOP_BOTTOM,
                            new int[] {
                                0xf40b0e14,
                                0xd80b0e14,
                                0xa00b0e14,
                                0x560b0e14,
                                0x1c0b0e14,
                                0x000b0e14
                            });
            topScrim.setBackground(scrimBg);
            topScrim.setAlpha(computeTopScrimAlpha(0f));
            a.root.addView(
                    topScrim,
                    new FrameLayout.LayoutParams(
                            -1, a.dp(Math.max(108, topSafeInsetDp + 52)), Gravity.TOP));

            topBrandPill = buildTopBrandPill();
            FrameLayout.LayoutParams brandLp =
                    new FrameLayout.LayoutParams(-2, a.dp(crossDp), Gravity.TOP | Gravity.LEFT);
            brandLp.leftMargin = a.dp(sideMarginDp);
            brandLp.topMargin = a.dp(topMarginDp);
            a.root.addView(topBrandPill, brandLp);

            boolean reducedTrans = a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
            GradientDrawable capsuleBg =
                    new GradientDrawable(
                            GradientDrawable.Orientation.TOP_BOTTOM,
                            reducedTrans
                                    ? new int[] {0xee1b202b, 0xee141922}
                                    : new int[] {0x9c141924, 0x8a0f141e});
            capsuleBg.setCornerRadius(a.dp(999));
            capsuleBg.setStroke(Math.max(1, a.dp(0.9f)), 0x38ffffff);
            rail.setBackground(capsuleBg);
        } else if (tvLeft) {
            TvV17Theme theme =
                    new TvV17Theme(
                            navScale,
                            1f,
                            a.reduced,
                            a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false));
            edgeShadeCollapsed = TvV17Surface.navigationEdge(theme, false);
            edgeShadeExpanded = TvV17Surface.navigationEdge(theme, true);
            edgeShade = new View(a);
            edgeShade.setTag("home-navigation-edge");
            edgeShade.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
            edgeShade.setBackground(edgeShadeCollapsed);
            a.root.addView(
                    edgeShade,
                    new FrameLayout.LayoutParams(
                            a.dp(crossDp + 42), -1, Gravity.LEFT | Gravity.TOP));
        } else {
            a.glass(rail, Math.round(25 * fitScale));
        }
        rail.setElevation(a.isTvDevice() ? 0 : a.dp(6));
        FrameLayout.LayoutParams size =
                tvTopLabeled
                        ? new FrameLayout.LayoutParams(
                                ViewGroup.LayoutParams.WRAP_CONTENT,
                                a.dp(crossDp),
                                Gravity.TOP | Gravity.RIGHT)
                        : horizontal
                                ? new FrameLayout.LayoutParams(
                                        a.dp(mainDp),
                                        a.dp(crossDp),
                                        (topMode ? Gravity.TOP : Gravity.BOTTOM)
                                                | Gravity.CENTER_HORIZONTAL)
                                : new FrameLayout.LayoutParams(
                                        a.dp(crossDp),
                                        a.windowHeight() - a.dp(32),
                                        Gravity.LEFT | Gravity.TOP);
        if (bottomMode) size.bottomMargin = a.dp(14);
        else if (tvTopLabeled) {
            size.topMargin = a.dp(topMarginDp);
            size.rightMargin = a.dp(sideMarginDp);
        } else if (topMode) size.topMargin = a.dp(topMarginDp);
        else {
            size.leftMargin = a.dp(12);
            size.topMargin = a.dp(topMarginDp);
        }
        a.root.addView(rail, size);
        if (topMode && !tvTopLabeled) {
            FrameLayout.LayoutParams viewport =
                    (FrameLayout.LayoutParams) a.scroll.getLayoutParams();
            viewport.topMargin = a.dp(crossDp + 34);
            a.scroll.setLayoutParams(viewport);
        }
        if (tvLeft) {
            addBrand();
            rail.addView(new View(a), new LinearLayout.LayoutParams(1, 0, 1));
        }
        Runnable homeAction =
                () -> {
                    if (a.scroll != null) a.smoothHomeScroll(0);
                    View target = a.root.findViewWithTag("home-curated-hero-play");
                    if (target == null || !target.isShown())
                        target = a.root.findViewWithTag("home-history:0");
                    if (target == null || !target.isShown())
                        target = a.root.findViewWithTag("home-tab:0");
                    if (target == null || !target.isShown())
                        target = a.root.findViewWithTag("source-switcher");
                    if (target == null || !target.isShown())
                        target = a.root.findViewWithTag("primary");
                    if (target != null) target.requestFocus();
                };
        Runnable searchAction = a::globalSearchDialog;
        Runnable historyAction = () -> a.open(new MainActivity.Screen(a::historyPage), true);
        Runnable liveAction = () -> a.open(new MainActivity.Screen(a::liveSources), true);
        Runnable favoriteAction =
                () ->
                        a.open(
                                new MainActivity.Screen(
                                        tvNav ? a::minePage : () -> new FavoritesScreen(a).show()),
                                true);
        final int accountIndex = tvNav ? 5 : 4;
        Runnable accountAction = () -> AccountPanel.show(a, items[accountIndex]);
        Runnable castAction = () -> a.open(new MainActivity.Screen(a::castScreen), true);
        Runnable settingsAction = () -> a.open(new MainActivity.Screen(a::settings), true);
        Runnable[] actions =
                tvNav
                        ? new Runnable[] {
                            homeAction,
                            searchAction,
                            historyAction,
                            liveAction,
                            favoriteAction,
                            accountAction,
                            castAction,
                            settingsAction
                        }
                        : new Runnable[] {
                            homeAction,
                            searchAction,
                            liveAction,
                            favoriteAction,
                            accountAction,
                            castAction,
                            settingsAction
                        };
        for (int i = 0; i < items.length; i++) {
            final int index = i;
            if (tvTopLabeled) {
                LinearLayout pillItem = a.row();
                pillItem.setTag(keys[i]);
                pillItem.setId(View.generateViewId());
                pillItem.setContentDescription(labels[i]);
                pillItem.setGravity(Gravity.CENTER);
                UiCompat.setDefaultFocusHighlightEnabled(pillItem, false);
                pillItem.setFocusable(true);
                pillItem.setFocusableInTouchMode(true);
                pillItem.setClickable(true);
                pillItem.setSelected(i == 0);
                pillItem.setPadding(
                        a.dp(Math.round(9.5f * fitScale)),
                        0,
                        a.dp(Math.round(10.5f * fitScale)),
                        0);
                a.pressFeedback(pillItem);

                Icon glyph = new Icon(i, iconKinds[i]);
                glyph.setFocusable(false);
                glyph.setClickable(false);
                int glyphSide = a.dp(Math.round(18 * fitScale));
                LinearLayout.LayoutParams gLp = new LinearLayout.LayoutParams(glyphSide, glyphSide);
                gLp.rightMargin = a.dp(Math.round(4.5f * fitScale));
                pillItem.addView(glyph, gLp);

                // Keep Typeface constant across focus changes so switching top tabs never
                // triggers requestLayout() on the rail.
                final TextView lbl =
                        a.text(
                                labels[i],
                                12.8f * fitScale,
                                i == 0 ? MainActivity.WHITE : 0xbce2ebf7);
                lbl.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, a.dp(12.8f * fitScale));
                lbl.setTypeface(null, Typeface.BOLD);
                lbl.setSingleLine(true);
                lbl.setIncludeFontPadding(false);
                pillItem.addView(lbl);

                items[i] = pillItem;
                LinearLayout.LayoutParams cell =
                        new LinearLayout.LayoutParams(
                                ViewGroup.LayoutParams.WRAP_CONTENT, a.dp(cellDp));
                int cellGap = a.dp(Math.max(1, Math.round(2 * fitScale)));
                cell.leftMargin = cellGap;
                cell.rightMargin = cellGap;
                rail.addView(pillItem, cell);
                pillItem.setOnClickListener(v -> actions[index].run());
                pillItem.setOnFocusChangeListener(
                        (v, focused) -> {
                            lbl.setTextColor(
                                    focused || pillItem.isSelected()
                                            ? MainActivity.WHITE
                                            : 0xbce2ebf7);
                            glyph.invalidate();
                            if (focused) selection.select(pillItem);
                            updateTopFocusBoost(contains(a.getCurrentFocus()));
                        });
                continue;
            }
            Icon icon = new Icon(i, iconKinds[i]);
            items[i] = icon;
            icon.setTag(keys[i]);
            icon.setId(View.generateViewId());
            icon.setContentDescription(labels[i]);
            UiCompat.setDefaultFocusHighlightEnabled(icon, false);
            icon.setFocusable(true);
            icon.setFocusableInTouchMode(true);
            icon.setClickable(true);
            icon.setSelected(i == 0);
            a.pressFeedback(icon);
            int cellGap = a.dp(Math.max(3, Math.round(4 * fitScale)));
            LinearLayout.LayoutParams cell =
                    new LinearLayout.LayoutParams(a.dp(cellDp), a.dp(cellDp));
            if (horizontal) {
                cell.leftMargin = cellGap;
                cell.rightMargin = cellGap;
            } else {
                cell.topMargin = cellGap;
                cell.bottomMargin = cellGap;
            }
            rail.addView(icon, cell);
            icon.setOnClickListener(v -> actions[index].run());
            icon.setOnFocusChangeListener(
                    (v, focused) -> {
                        icon.invalidate();
                        if (!tvLeft) {
                            FocusMotion.style(
                                    a,
                                    icon,
                                    focused,
                                    Color.TRANSPARENT,
                                    Color.TRANSPARENT,
                                    Math.max(8, Math.round(10.5f * fitScale)),
                                    MainActivity.WHITE,
                                    MainActivity.WHITE,
                                    false,
                                    1.04f);
                            icon.setBackground(null);
                        }
                        if (focused) selection.select(icon);
                    });
        }
        if (tvLeft) rail.addView(new View(a), new LinearLayout.LayoutParams(1, 0, 1));
        for (int i = 0; i < items.length; i++) {
            if (horizontal) {
                items[i].setNextFocusLeftId(items[Math.max(0, i - 1)].getId());
                items[i].setNextFocusRightId(items[Math.min(items.length - 1, i + 1)].getId());
            } else {
                items[i].setNextFocusUpId(items[Math.max(0, i - 1)].getId());
                items[i].setNextFocusDownId(items[Math.min(items.length - 1, i + 1)].getId());
                if (tvLeft) items[i].setNextFocusLeftId(items[i].getId());
                else items[i].setNextFocusRightId(items[i].getId());
            }
        }
        a.root.getViewTreeObserver()
                .addOnGlobalFocusChangeListener(
                        (oldFocus, newFocus) -> {
                            boolean inDock = contains(newFocus);
                            if (inDock
                                    && oldFocus != null
                                    && !contains(oldFocus)
                                    && oldFocus.getTag() instanceof String
                                    && a.current != null) {
                                a.current.homeReturnFocus = (String) oldFocus.getTag();
                                navigation.remember(oldFocus);
                            }
                            if (tvLeft) setExpanded(inDock);
                            if (tvTopLabeled && contains(oldFocus) != inDock) {
                                updateTopFocusBoost(inDock);
                            }
                            if (newFocus != null
                                    && !inDock
                                    && contains(oldFocus)
                                    && newFocus.getRootView() == a.root.getRootView())
                                selection.select(items[0]);
                        });
        selection.select(items[0]);
    }

    private LinearLayout buildTopBrandPill() {
        LinearLayout pill = a.row();
        pill.setTag("home-brand");
        pill.setFocusable(false);
        pill.setClickable(false);
        pill.setDescendantFocusability(ViewGroup.FOCUS_BLOCK_DESCENDANTS);
        pill.setGravity(Gravity.CENTER_VERTICAL);
        pill.setBackground(null);
        pill.setElevation(0);
        pill.setPivotX(0f);
        pill.setPivotY(0f);

        ImageView mark = new ImageView(a);
        mark.setTag("home-brand-mark");
        mark.setImageResource(R.drawable.logo_mark);
        mark.setScaleType(ImageView.ScaleType.FIT_CENTER);
        int side = a.dp(Math.round(28 * fitScale));
        LinearLayout.LayoutParams iconLp = new LinearLayout.LayoutParams(side, side);
        iconLp.rightMargin = a.dp(Math.round(9 * fitScale));
        pill.addView(mark, iconLp);

        brandText = a.text("Marco Movie", 16f * fitScale, MainActivity.WHITE);
        brandText.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, a.dp(16f * fitScale));
        brandText.setTag("home-brand-word");
        brandText.setTypeface(null, Typeface.BOLD);
        brandText.setSingleLine(true);
        brandText.setIncludeFontPadding(false);
        brandText.setShadowLayer(a.dp(8), 0, a.dp(2), 0xb8000000);
        pill.addView(brandText);
        return pill;
    }

    /** Runtime safety guard: if OEM font metrics still push rail near brand, scale both cleanly. */
    private void reconcileTopOverflow() {
        if (!tvTopLabeled || topBrandPill == null || a.root == null) return;
        int rootW = a.root.getWidth();
        int brandW = topBrandPill.getWidth();
        int railW = rail.getWidth();
        if (rootW <= 0 || brandW <= 0 || railW <= 0) return;
        int marginPx = a.dp(sideMarginDp);
        int minGapPx = a.dp(16);
        int available = rootW - marginPx * 2 - minGapPx;
        int needed = brandW + railW;
        float nextOverflow = needed > available && available > 0 ? available / (float) needed : 1f;
        nextOverflow = Math.max(0.65f, Math.min(1f, nextOverflow));
        if (Math.abs(nextOverflow - runtimeOverflowScale) > 0.01f) {
            runtimeOverflowScale = nextOverflow;
            applyTopShrink(lastScrollProgress < 0f ? 0f : lastScrollProgress, false);
        }
    }

    private void updateTopFocusBoost(boolean focused) {
        if (!tvTopLabeled || topFocused == focused) return;
        topFocused = focused;
        rail.invalidate();
        applyTopShrink(lastScrollProgress < 0f ? 0f : lastScrollProgress, !a.reduced);
    }

    void onScrollY(int scrollY) {
        if (!tvTopLabeled) return;
        float progress = computeTopShrinkProgress(scrollY, a.dp(260));
        if (Math.abs(progress - lastScrollProgress) < 0.008f) return;
        lastScrollProgress = progress;
        applyTopShrink(progress, false);
    }

    private void applyTopShrink(float progress, boolean animate) {
        float smooth = progress * progress * (3f - 2f * progress);
        float effective = topFocused ? 0f : smooth;
        float scrimAlpha =
                topFocused
                        ? Math.max(0.58f, computeTopScrimAlpha(progress))
                        : computeTopScrimAlpha(progress);
        float targetScale = (1f - 0.08f * effective) * runtimeOverflowScale;
        float targetTy = -a.dp(4) * effective;
        float brandAlpha = 1f - 0.08f * effective;
        float railAlpha = topFocused ? 1f : (1f - 0.06f * effective);

        if (animate) {
            android.view.animation.DecelerateInterpolator decel = topDecel();
            if (topScrim != null) {
                topScrim.animate().cancel();
                topScrim.animate()
                        .alpha(scrimAlpha)
                        .setDuration(140)
                        .setInterpolator(decel)
                        .start();
            }
            if (topBrandPill != null) {
                topBrandPill.animate().cancel();
                topBrandPill
                        .animate()
                        .scaleX(targetScale)
                        .scaleY(targetScale)
                        .translationY(targetTy)
                        .alpha(brandAlpha)
                        .setDuration(140)
                        .setInterpolator(decel)
                        .start();
            }
            rail.animate().cancel();
            rail.animate()
                    .scaleX(targetScale)
                    .scaleY(targetScale)
                    .translationY(targetTy)
                    .alpha(railAlpha)
                    .setDuration(140)
                    .setInterpolator(decel)
                    .start();
            return;
        }
        if (topScrim != null) {
            topScrim.animate().cancel();
            topScrim.setAlpha(scrimAlpha);
        }
        if (topBrandPill != null) {
            topBrandPill.animate().cancel();
            topBrandPill.setScaleX(targetScale);
            topBrandPill.setScaleY(targetScale);
            topBrandPill.setTranslationY(targetTy);
            topBrandPill.setAlpha(brandAlpha);
        }
        rail.animate().cancel();
        rail.setScaleX(targetScale);
        rail.setScaleY(targetScale);
        rail.setTranslationY(targetTy);
        rail.setAlpha(railAlpha);
    }

    void focusFromMenuKey() {
        if (!topMode || items.length == 0) return;
        View current = a.getCurrentFocus();
        if (contains(current)) {
            returnToContent();
            return;
        }
        if (current != null && !contains(current)) {
            menuReturnRef = new java.lang.ref.WeakReference<>(current);
            navigation.remember(current);
            if (current.getTag() instanceof String && a.current != null) {
                a.current.homeReturnFocus = (String) current.getTag();
            }
        }
        items[0].requestFocus();
    }

    void selectSection(boolean library) {
        if (!tvLeft && !tvTopLabeled) return;
        items[0].setSelected(true);
        items[0].invalidate();
        if (!contains(a.getCurrentFocus())) selection.select(items[0]);
    }

    void setExpanded(boolean value) {
        if (!tvLeft || expanded == value) return;
        expanded = value;
        FrameLayout.LayoutParams railLp = (FrameLayout.LayoutParams) rail.getLayoutParams();
        railLp.width = a.dp(value ? Math.round(164 * fitScale) : crossDp);
        rail.setLayoutParams(railLp);
        if (edgeShade != null) {
            FrameLayout.LayoutParams shadeLp =
                    (FrameLayout.LayoutParams) edgeShade.getLayoutParams();
            shadeLp.width = a.dp(value ? Math.round(236 * fitScale) : crossDp + 42);
            edgeShade.setLayoutParams(shadeLp);
            edgeShade.setBackground(value ? edgeShadeExpanded : edgeShadeCollapsed);
        }
        if (brandText != null) brandText.setVisibility(value ? View.VISIBLE : View.INVISIBLE);
        int itemW = value ? ViewGroup.LayoutParams.MATCH_PARENT : a.dp(cellDp);
        for (View item : items) {
            LinearLayout.LayoutParams lp = (LinearLayout.LayoutParams) item.getLayoutParams();
            if (lp.width != itemW) {
                lp.width = itemW;
                item.setLayoutParams(lp);
            }
            item.invalidate();
        }
        selection.snapToTarget();
    }

    private void addBrand() {
        FrameLayout brand = new FrameLayout(a);
        brand.setTag("home-brand");
        brand.setFocusable(false);
        brand.setClickable(false);
        brand.setDescendantFocusability(ViewGroup.FOCUS_BLOCK_DESCENDANTS);
        brand.setContentDescription("Marco Movie");
        LinearLayout.LayoutParams header =
                new LinearLayout.LayoutParams(-1, a.dp(Math.round(44 * fitScale)));
        header.bottomMargin = a.dp(Math.round(8 * fitScale));
        rail.addView(brand, header);
        ImageView mark = new ImageView(a);
        mark.setTag("home-brand-mark");
        mark.setImageResource(R.drawable.logo_mark);
        mark.setScaleType(ImageView.ScaleType.FIT_CENTER);
        int side = a.dp(32 * fitScale);
        FrameLayout.LayoutParams icon =
                new FrameLayout.LayoutParams(side, side, Gravity.LEFT | Gravity.CENTER_VERTICAL);
        // The header fills the rail. Its left edge/padding never changes when expanded.
        icon.leftMargin = (a.dp(crossDp) - side) / 2 - rail.getPaddingLeft();
        brand.addView(mark, icon);
        brandText = a.text("MARCO MOVIE", 14 * fitScale, MainActivity.WHITE);
        brandText.setTag("home-brand-word");
        brandText.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, a.dp(14 * fitScale));
        brandText.setTypeface(null, Typeface.BOLD);
        brandText.setIncludeFontPadding(false);
        brandText.setSingleLine(true);
        brandText.setGravity(Gravity.CENTER_VERTICAL);
        brandText.setVisibility(View.INVISIBLE);
        FrameLayout.LayoutParams label = new FrameLayout.LayoutParams(-1, -1);
        label.leftMargin = a.dp(48 * fitScale) - rail.getPaddingLeft();
        brand.addView(brandText, label);
    }

    boolean contains(View view) {
        for (View item : items) if (item == view) return true;
        return false;
    }

    void leftEdge(View view, boolean library) {
        if (view != null && tvLeft) view.setNextFocusLeftId(items[0].getId());
    }

    boolean key(KeyEvent event) {
        View focused = a.getCurrentFocus();
        if (!contains(focused)) return false;
        int key = event.getKeyCode();
        if ((tvLeft || topMode) && key == KeyEvent.KEYCODE_BACK) {
            if (event.getAction() == KeyEvent.ACTION_UP && !event.isCanceled()) returnToContent();
            return true;
        }
        if (horizontal
                && (key == KeyEvent.KEYCODE_DPAD_LEFT || key == KeyEvent.KEYCODE_DPAD_RIGHT)) {
            if (event.getAction() == KeyEvent.ACTION_DOWN) {
                int index = 0;
                while (index < items.length - 1 && items[index] != focused) index++;
                items[
                        Math.max(
                                0,
                                Math.min(
                                        items.length - 1,
                                        index + (key == KeyEvent.KEYCODE_DPAD_LEFT ? -1 : 1)))]
                        .requestFocus();
            }
            return true;
        }
        int exit =
                topMode
                        ? KeyEvent.KEYCODE_DPAD_DOWN
                        : bottomMode
                                ? KeyEvent.KEYCODE_DPAD_UP
                                : tvLeft ? KeyEvent.KEYCODE_DPAD_RIGHT : KeyEvent.KEYCODE_DPAD_LEFT;
        if (key != exit)
            return horizontal
                    && (key == KeyEvent.KEYCODE_DPAD_UP || key == KeyEvent.KEYCODE_DPAD_DOWN);
        if (event.getAction() == KeyEvent.ACTION_DOWN && event.getRepeatCount() == 0) {
            returnToContent();
        }
        return true;
    }

    void returnToContent() {
        View target = menuReturnRef != null ? menuReturnRef.get() : null;
        menuReturnRef = null;
        if (target == null
                || !target.isAttachedToWindow()
                || !target.isShown()
                || !target.isFocusable()
                || !target.isEnabled()) {
            target =
                    a.current == null || a.current.homeReturnFocus == null
                            ? null
                            : a.root.findViewWithTag(a.current.homeReturnFocus);
        }
        if (target == null
                || !target.isAttachedToWindow()
                || !target.isShown()
                || !target.isFocusable()
                || !target.isEnabled()) {
            View fallback = a.root.findViewWithTag("home-curated-hero-play");
            if (fallback == null || !fallback.isShown())
                fallback = a.root.findViewWithTag("home-history:0");
            if (fallback == null || !fallback.isShown())
                fallback = a.root.findViewWithTag("home-tab:0");
            if (fallback == null || !fallback.isShown())
                fallback = a.root.findViewWithTag("source-switcher");
            target = navigation.restore(a.root, fallback);
        }
        if (target == null) target = a.root.findViewWithTag("primary");
        if (target != null && target.isShown() && target.isFocusable()) {
            if (topMode && a.scroll instanceof TvScrollView && isInViewport(a.scroll, target)) {
                ((TvScrollView) a.scroll).suppressNextReveal = true;
            }
            target.requestFocus();
        }
    }

    private static boolean isInViewport(android.widget.ScrollView scroller, View target) {
        if (scroller == null || target == null || scroller.getHeight() <= 0) return false;
        ViewParent p = target.getParent();
        while (p != null && p != scroller) p = p.getParent();
        if (p != scroller) return false;
        Rect rect = new Rect(0, 0, target.getWidth(), target.getHeight());
        scroller.offsetDescendantRectToMyCoords(target, rect);
        int sy = scroller.getScrollY();
        return rect.bottom > sy && rect.top < sy + scroller.getHeight();
    }

    final class Icon extends View {
        final int itemIndex;
        final int kind;
        final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        final Path path = new Path();
        final RectF box = new RectF();
        final Typeface labelTypeface = Typeface.DEFAULT;

        Icon(int itemIndex, int kind) {
            super(a);
            this.itemIndex = itemIndex;
            this.kind = kind;
        }

        float snap(float value, int strokePx) {
            return (strokePx & 1) == 0 ? Math.round(value) : (float) Math.floor(value) + 0.5f;
        }

        @Override
        protected void onDraw(Canvas c) {
            super.onDraw(c);
            int w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            float size =
                    tvTopLabeled
                            ? Math.min(w, h) * 0.86f
                            : a.dp((a.isTvDevice() ? 25f : 22f) * fitScale);
            float r = size * 0.5f;
            float cx =
                    tvLeft && expanded
                            ? a.dp(cellDp / 2f)
                            : w * 0.5f + (!horizontal && isSelected() ? a.dp(1f) : 0f);
            float cy = h * 0.5f - (!tvTopLabeled && horizontal && isSelected() ? a.dp(1.2f) : 0f);
            int strokePx =
                    Math.max(
                            2,
                            Math.round(
                                    a.dp(
                                            (tvTopLabeled ? 1.65f : (a.isTvDevice() ? 2.0f : 1.75f))
                                                    * fitScale)));
            int fg = hasFocus() ? MainActivity.WHITE : 0xffedf2f8;
            p.reset();
            p.setAntiAlias(true);
            p.setColor(fg);
            p.setStyle(Paint.Style.STROKE);
            p.setStrokeWidth(strokePx);
            p.setStrokeCap(Paint.Cap.ROUND);
            p.setStrokeJoin(Paint.Join.ROUND);

            int drawingKind = kind;
            switch (drawingKind) {
                case 0:
                    {
                        path.reset();
                        float roofY = snap(cy - r * 0.06f, strokePx);
                        float peakY = snap(cy - r * 0.84f, strokePx);
                        path.moveTo(cx - r * 0.88f, roofY);
                        path.lineTo(cx, peakY);
                        path.lineTo(cx + r * 0.88f, roofY);
                        c.drawPath(path, p);

                        path.reset();
                        float leftX = snap(cx - r * 0.58f, strokePx);
                        float rightX = snap(cx + r * 0.58f, strokePx);
                        float wallTop = snap(cy - r * 0.12f, strokePx);
                        float bottomY = snap(cy + r * 0.80f, strokePx);
                        float doorLeft = snap(cx - r * 0.18f, strokePx);
                        float doorRight = snap(cx + r * 0.18f, strokePx);
                        float doorTop = snap(cy + r * 0.26f, strokePx);
                        path.moveTo(leftX, wallTop);
                        path.lineTo(leftX, bottomY);
                        path.lineTo(doorLeft, bottomY);
                        path.lineTo(doorLeft, doorTop);
                        path.lineTo(doorRight, doorTop);
                        path.lineTo(doorRight, bottomY);
                        path.lineTo(rightX, bottomY);
                        path.lineTo(rightX, wallTop);
                        c.drawPath(path, p);
                        break;
                    }
                case 1:
                    {
                        float lx = cx - r * 0.14f;
                        float ly = cy - r * 0.14f;
                        float lensR = r * 0.55f;
                        c.drawCircle(lx, ly, lensR, p);
                        float start = lensR * 0.72f;
                        c.drawLine(lx + start, ly + start, cx + r * 0.80f, cy + r * 0.80f, p);
                        break;
                    }
                case 2:
                    {
                        float left = snap(cx - r * 0.84f, strokePx);
                        float top = snap(cy - r * 0.72f, strokePx);
                        float right = snap(cx + r * 0.84f, strokePx);
                        float bottom = snap(cy + r * 0.42f, strokePx);
                        box.set(left, top, right, bottom);
                        float corner = r * 0.22f;
                        c.drawRoundRect(box, corner, corner, p);
                        float stemX = snap(cx, strokePx);
                        float standY = snap(cy + r * 0.80f, strokePx);
                        c.drawLine(stemX, bottom, stemX, standY, p);
                        c.drawLine(
                                snap(cx - r * 0.42f, strokePx),
                                standY,
                                snap(cx + r * 0.42f, strokePx),
                                standY,
                                p);
                        p.setStyle(Paint.Style.FILL);
                        path.reset();
                        float midY = (top + bottom) * 0.5f;
                        path.moveTo(cx - r * 0.15f, midY - r * 0.25f);
                        path.lineTo(cx + r * 0.25f, midY);
                        path.lineTo(cx - r * 0.15f, midY + r * 0.25f);
                        path.close();
                        c.drawPath(path, p);
                        break;
                    }
                case 3:
                    {
                        path.reset();
                        float topDipY = cy - r * 0.36f;
                        float bottomTipY = cy + r * 0.78f;
                        float lobePeakY = cy - r * 0.84f;
                        float sideX = r * 0.86f;
                        float sideY = cy - r * 0.16f;
                        path.moveTo(cx, bottomTipY);
                        path.cubicTo(
                                cx - r * 0.38f,
                                cy + r * 0.48f,
                                cx - sideX,
                                cy + r * 0.18f,
                                cx - sideX,
                                sideY);
                        path.cubicTo(cx - sideX, lobePeakY, cx - r * 0.24f, lobePeakY, cx, topDipY);
                        path.cubicTo(
                                cx + r * 0.24f,
                                lobePeakY,
                                cx + sideX,
                                lobePeakY,
                                cx + sideX,
                                sideY);
                        path.cubicTo(
                                cx + sideX,
                                cy + r * 0.18f,
                                cx + r * 0.38f,
                                cy + r * 0.48f,
                                cx,
                                bottomTipY);
                        path.close();
                        c.drawPath(path, p);
                        break;
                    }
                case 4:
                    {
                        path.reset();
                        float baseY = snap(cy + r * 0.54f, strokePx);
                        float leftTop = snap(cy - r * 0.08f, strokePx);
                        float rightTop = snap(cy - r * 0.02f, strokePx);
                        path.moveTo(cx - r * 0.52f, baseY);
                        path.cubicTo(
                                cx - r * 0.94f,
                                baseY,
                                cx - r * 0.94f,
                                leftTop,
                                cx - r * 0.50f,
                                leftTop);
                        path.cubicTo(
                                cx - r * 0.44f,
                                cy - r * 0.78f,
                                cx + r * 0.36f,
                                cy - r * 0.82f,
                                cx + r * 0.52f,
                                rightTop);
                        path.cubicTo(
                                cx + r * 0.92f,
                                rightTop,
                                cx + r * 0.92f,
                                baseY,
                                cx + r * 0.52f,
                                baseY);
                        path.close();
                        c.drawPath(path, p);
                        break;
                    }
                case 5:
                    {
                        float left = snap(cx - r * 0.84f, strokePx);
                        float top = snap(cy - r * 0.68f, strokePx);
                        float right = snap(cx + r * 0.84f, strokePx);
                        float bottom = snap(cy + r * 0.68f, strokePx);
                        float cr = r * 0.22f;
                        path.reset();
                        path.moveTo(left, cy - r * 0.14f);
                        path.lineTo(left, top + cr);
                        box.set(left, top, left + cr * 2f, top + cr * 2f);
                        path.arcTo(box, 180f, 90f, false);
                        path.lineTo(right - cr, top);
                        box.set(right - cr * 2f, top, right, top + cr * 2f);
                        path.arcTo(box, 270f, 90f, false);
                        path.lineTo(right, bottom - cr);
                        box.set(right - cr * 2f, bottom - cr * 2f, right, bottom);
                        path.arcTo(box, 0f, 90f, false);
                        path.lineTo(cx + r * 0.08f, bottom);
                        c.drawPath(path, p);

                        float r1 = r * 0.42f;
                        box.set(left - r1, bottom - r1, left + r1, bottom + r1);
                        c.drawArc(box, 270f, 90f, false, p);
                        float r2 = r * 0.78f;
                        box.set(left - r2, bottom - r2, left + r2, bottom + r2);
                        c.drawArc(box, 270f, 90f, false, p);

                        p.setStyle(Paint.Style.FILL);
                        c.drawCircle(
                                left + r * 0.05f,
                                bottom - r * 0.05f,
                                Math.max(1.5f, strokePx * 0.75f),
                                p);
                        break;
                    }
                case 7:
                    {
                        box.set(cx - r * .78f, cy - r * .72f, cx + r * .68f, cy + r * .8f);
                        c.drawRoundRect(box, r * .16f, r * .16f, p);
                        path.reset();
                        path.moveTo(cx - r * .18f, cy - r * .35f);
                        path.lineTo(cx + r * .38f, cy);
                        path.lineTo(cx - r * .18f, cy + r * .35f);
                        path.close();
                        c.drawPath(path, p);
                        break;
                    }
                case 6:
                    {
                        float xLeft = snap(cx - r * 0.82f, strokePx);
                        float xRight = snap(cx + r * 0.82f, strokePx);
                        float knobR = r * 0.20f;
                        float clearance = knobR + strokePx * 0.65f;
                        float[] rowsY = {
                            snap(cy - r * 0.58f, strokePx),
                            snap(cy, strokePx),
                            snap(cy + r * 0.58f, strokePx)
                        };
                        float[] knobsX = {cx - r * 0.24f, cx + r * 0.26f, cx - r * 0.24f};
                        for (int i = 0; i < 3; i++) {
                            float y = rowsY[i], kx = knobsX[i];
                            if (kx - clearance > xLeft) {
                                c.drawLine(xLeft, y, kx - clearance, y, p);
                            }
                            if (xRight > kx + clearance) {
                                c.drawLine(kx + clearance, y, xRight, y, p);
                            }
                            c.drawCircle(kx, y, knobR, p);
                        }
                        break;
                    }
                case ICON_HISTORY:
                    {
                        float clockR = r * 0.74f;
                        box.set(cx - clockR, cy - clockR, cx + clockR, cy + clockR);
                        // Open counter-clockwise history arc from ~135° sweeping 290°
                        c.drawArc(box, -155f, 295f, false, p);
                        // Counter-clockwise arrowhead on top-left of arc
                        float ax = cx - clockR * 0.86f;
                        float ay = cy - clockR * 0.42f;
                        path.reset();
                        path.moveTo(ax - r * 0.08f, ay - r * 0.34f);
                        path.lineTo(ax, ay + r * 0.04f);
                        path.lineTo(ax + r * 0.36f, ay - r * 0.08f);
                        c.drawPath(path, p);
                        // Clock hands
                        c.drawLine(
                                snap(cx, strokePx),
                                snap(cy - clockR * 0.48f, strokePx),
                                snap(cx, strokePx),
                                snap(cy, strokePx),
                                p);
                        c.drawLine(
                                snap(cx, strokePx),
                                snap(cy, strokePx),
                                cx + clockR * 0.38f,
                                cy + clockR * 0.24f,
                                p);
                        break;
                    }
            }
            if (tvLeft && expanded) {
                p.setStyle(Paint.Style.FILL);
                p.setColor(hasFocus() ? MainActivity.WHITE : 0xffc5ced8);
                p.setTextSize(a.dp(15f * fitScale));
                p.setTypeface(labelTypeface);
                c.drawText(
                        labels[itemIndex],
                        a.dp(48 * fitScale),
                        cy - (p.ascent() + p.descent()) / 2,
                        p);
            }
            if (isSelected() && !tvTopLabeled) {
                p.setStyle(Paint.Style.FILL);
                p.setColor(MainActivity.WHITE);
                float dotRadius = Math.max(1.5f, a.dp(1.6f * fitScale));
                if (horizontal) {
                    c.drawCircle(w * 0.5f, h - a.dp(3.5f * fitScale), dotRadius, p);
                } else {
                    c.drawCircle(a.dp(3.5f * fitScale), h * 0.5f, dotRadius, p);
                }
            }
        }

        @Override
        public CharSequence getAccessibilityClassName() {
            return Button.class.getName();
        }
    }
}
