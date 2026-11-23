package com.pilipala.marcomovie;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RadialGradient;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.io.File;
import java.util.ArrayList;
import java.util.List;

/**
 * Modular Android Mobile & Tablet root shell:
 * - {@code 4 + 1} Liquid Glass floating bottom dock ({@code 发现 · 直播 · 片库 · 设置} + detached circular
 *   {@code 🔍} Search pill on the right); switches to a vertical glass rail on landscape tablets.
 * - Scroll-driven dock collapse/hide ({@code 常驻} / {@code 上滑折叠保留搜索钮} / {@code 上滑自动隐藏}).
 * - Long-press or upward drag on the {@code 发现} tab opens the quick Source & Home-Mode switcher.
 */
final class MobileRootShell {
    static final int TAB_HOME = 0;
    static final int TAB_LIVE = 1;
    static final int TAB_LIBRARY = 2;
    static final int TAB_SETTINGS = 3;
    static final int TAB_SEARCH = 4;

    static int activeTab = TAB_HOME;
    static int librarySubTab = 0;
    static int settingsSubPage = 0;
    static String settingsHighlightKey = "";
    static String pendingSearchKeyword = "";

    final MainActivity a;
    FrameLayout shellRoot;
    FrameLayout contentContainer;
    AmbientCanvasView ambientCanvas;
    LinearLayout floatingDockWrap;
    LinearLayout mainCapsule;
    View collapsedPill;
    View searchBubble;
    boolean dockCollapsed;
    boolean renderedPortrait;
    Cms.Site activeSite;
    Runnable reloadCategory;

    private final View[] tabItemViews = new View[4];
    private final NavIconView[] tabIconViews = new NavIconView[4];
    private final TextView[] tabLabelViews = new TextView[4];

    MobileRootShell(MainActivity activity) {
        this.a = activity;
    }

    static void resetStaticState() {
        activeTab = TAB_HOME;
        librarySubTab = 0;
        settingsSubPage = 0;
        settingsHighlightKey = "";
        pendingSearchKeyword = "";
        MobileSearchPage.clearCachedResults();
    }

    static void show(MainActivity a) {
        MobileRootShell shell = new MobileRootShell(a);
        a.mobileShell = shell;
        shell.render();
    }

    static void openTab(MainActivity a, int tab) {
        activeTab = tab;
        if (tab == TAB_SETTINGS) settingsSubPage = 0;
        if (a.current != null && a.current.home && a.mobileShell != null) {
            a.mobileShell.switchTab(tab);
        } else {
            a.open(new MainActivity.Screen(() -> show(a)), false);
        }
    }

    static void openSearch(MainActivity a, String initialKeyword) {
        if (initialKeyword != null && !initialKeyword.trim().isEmpty()) {
            pendingSearchKeyword = initialKeyword.trim();
        }
        openTab(a, TAB_SEARCH);
    }

    boolean resume() {
        if (shellRoot == null
                || contentContainer == null
                || a.isPortrait() != renderedPortrait
                || a.isFinishing()) {
            return false;
        }
        a.applyMobileSystemBars(false);
        a.root = shellRoot;
        a.setContentView(shellRoot);
        a.watchRootLayout(shellRoot);
        expandDock();
        return true;
    }

    boolean handleBack() {
        if (activeTab == TAB_SETTINGS && settingsSubPage != 0) {
            settingsSubPage = 0;
            settingsHighlightKey = "";
            switchTab(TAB_SETTINGS);
            return true;
        }
        if (activeTab != TAB_HOME) {
            switchTab(TAB_HOME);
            return true;
        }
        return false;
    }

    void resolveActiveSite() {
        activeSite = null;
        if (a.config == null || a.config.sites.isEmpty()) return;
        String saved = a.prefs.getString(Prefs.SELECTED_SITE, "");
        for (Cms.Site s : a.config.sites) {
            if (s.key.equals(saved) && a.available(s)) {
                activeSite = s;
                return;
            }
        }
        for (Cms.Site s : a.config.sites) {
            if (a.available(s)) {
                activeSite = s;
                a.prefs.edit().putString(Prefs.SELECTED_SITE, s.key).apply();
                return;
            }
        }
    }

    void setAmbientColor(int color) {
        if (ambientCanvas != null && a.mobilePrefs().getBoolean(Prefs.COVER_AMBIENT, true)) {
            ambientCanvas.setDynamicTint(color);
        }
    }

    void bindScrollBehavior(final ScrollView sv) {
        if (sv == null) return;
        final int[] lastY = {0};
        sv.getViewTreeObserver()
                .addOnScrollChangedListener(
                        () -> {
                            int y = sv.getScrollY();
                            int dy = y - lastY[0];
                            lastY[0] = y;
                            int behavior = a.mobilePrefs().getInt(Prefs.NAV_SCROLL_BEHAVIOR, 1);
                            if (behavior == 0 || floatingDockWrap == null) return;
                            if (y < a.dp(24) || dy < -a.dp(10)) {
                                expandDock();
                            } else if (dy > a.dp(14) && y > a.dp(72)) {
                                collapseDock(behavior == 2);
                            }
                        });
    }

    private void collapseDock(boolean fullHide) {
        if (floatingDockWrap == null || dockCollapsed) return;
        dockCollapsed = true;
        if (fullHide) {
            floatingDockWrap
                    .animate()
                    .translationY(a.dp(110))
                    .alpha(0f)
                    .setDuration(a.reduced ? 0 : 180)
                    .start();
        } else {
            if (mainCapsule != null) mainCapsule.setVisibility(View.GONE);
            if (collapsedPill != null) collapsedPill.setVisibility(View.VISIBLE);
        }
    }

    void expandDock() {
        if (floatingDockWrap == null || !dockCollapsed) return;
        dockCollapsed = false;
        floatingDockWrap
                .animate()
                .translationY(0f)
                .alpha(1f)
                .setDuration(a.reduced ? 0 : 160)
                .start();
        if (mainCapsule != null) mainCapsule.setVisibility(View.VISIBLE);
        if (collapsedPill != null) collapsedPill.setVisibility(View.GONE);
    }

    void render() {
        a.clearPlaybackLoading();
        a.cancelArtwork();
        a.cancelPageRequests();
        if (a.current != null) {
            a.current.home = true;
            a.current.mobileHome = this;
        }
        if (a.inlinePlayer != null) {
            a.inlinePlayer.detach();
            a.inlinePlayer = null;
        }
        a.stopWeb();
        a.stopMagnet();
        a.releasePlayer();
        a.generation++;

        a.applyMobileSystemBars(false);
        resolveActiveSite();

        shellRoot = new FrameLayout(a);
        shellRoot.setBackgroundColor(0xff070b0a);
        a.root = shellRoot;
        a.setContentView(shellRoot);
        a.watchRootLayout(shellRoot);
        renderedPortrait = a.isPortrait();
        final boolean builtPortrait = renderedPortrait;
        shellRoot.addOnLayoutChangeListener(
                (view, l, t, r, b, ol, ot, or, ob) -> {
                    int w = r - l, h = b - t;
                    if (w <= 0 || h <= 0 || a.root != shellRoot) return;
                    a.usableWidth = w;
                    a.usableHeight = h;
                    if ((w < h) != builtPortrait) {
                        a.ui.post(
                                () -> {
                                    if (!a.isFinishing()
                                            && !a.isDestroyed()
                                            && a.root == shellRoot
                                            && a.current != null
                                            && a.current.home) {
                                        show(a);
                                    }
                                });
                    }
                });

        ambientCanvas = new AmbientCanvasView(a);
        shellRoot.addView(ambientCanvas, new FrameLayout.LayoutParams(-1, -1));

        float widthDp = a.windowWidth() / a.getResources().getDisplayMetrics().density;
        boolean sideRail = widthDp >= 640 && !a.isPortrait();

        if (sideRail) {
            LinearLayout mainRow = a.row();
            mainRow.setGravity(Gravity.TOP);
            shellRoot.addView(mainRow, new FrameLayout.LayoutParams(-1, -1));

            FrameLayout railWrap = new FrameLayout(a);
            railWrap.setPadding(a.dp(12), a.statusBarHeight() + a.dp(12), a.dp(6), a.dp(12));
            LinearLayout rail = buildVerticalSideRail();
            railWrap.addView(
                    rail, new FrameLayout.LayoutParams(a.dp(68), -2, Gravity.CENTER_VERTICAL));
            mainRow.addView(railWrap, new LinearLayout.LayoutParams(-2, -1));

            contentContainer = new FrameLayout(a);
            mainRow.addView(contentContainer, new LinearLayout.LayoutParams(0, -1, 1f));
        } else {
            contentContainer = new FrameLayout(a);
            shellRoot.addView(contentContainer, new FrameLayout.LayoutParams(-1, -1));

            floatingDockWrap = buildFloatingBottomDock();
            FrameLayout.LayoutParams dockLp =
                    new FrameLayout.LayoutParams(
                            -2, -2, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
            dockLp.bottomMargin = a.dp(16);
            shellRoot.addView(floatingDockWrap, dockLp);
        }

        switchTab(activeTab);
    }

    private LinearLayout buildFloatingBottomDock() {
        boolean compactFlat = a.mobilePrefs().getInt(Prefs.NAV_STYLE, 0) == 1;
        boolean solid = a.isReducedTransparency();
        int accent = a.mobileAccentColor();

        LinearLayout outer = a.row();
        outer.setGravity(Gravity.CENTER_VERTICAL);
        outer.setTag("mobile-bottom-dock");

        // 1. Main 4-tab Liquid Glass capsule
        mainCapsule = a.row();
        mainCapsule.setGravity(Gravity.CENTER_VERTICAL);
        mainCapsule.setPadding(a.dp(6), a.dp(5), a.dp(6), a.dp(5));
        GradientDrawable capBg =
                solid
                        ? UiWidgets.glassBg(0xf8141a18, 0xf80e1312, a.dp(999), a.dp(1f), 0x33ffffff)
                        : UiWidgets.glassBg(
                                0xd61c2522, 0xe0111715, a.dp(999), a.dp(1f), 0x40ffffff);
        mainCapsule.setBackground(capBg);
        UiCompat.setElevation(mainCapsule, a.dp(12));

        String[] names = {"发现", "直播", "片库", "设置"};
        int[] icons = {
            NavIconView.KIND_DISCOVER,
            NavIconView.KIND_LIVE,
            NavIconView.KIND_LIBRARY,
            NavIconView.KIND_SETTINGS
        };
        for (int i = 0; i < 4; i++) {
            final int idx = i;
            LinearLayout cell = a.vertical();
            cell.setGravity(Gravity.CENTER);
            cell.setPadding(
                    a.dp(compactFlat ? 14 : 15), a.dp(6), a.dp(compactFlat ? 14 : 15), a.dp(6));
            cell.setTag("mobile-nav:" + idx);
            NavIconView icon = new NavIconView(a, icons[i]);
            tabIconViews[i] = icon;
            cell.addView(icon, new LinearLayout.LayoutParams(a.dp(21), a.dp(21)));
            TextView lbl = a.text(names[i], 10.5f, MainActivity.MUTED);
            lbl.setPadding(0, a.dp(2), 0, 0);
            tabLabelViews[i] = lbl;
            cell.addView(lbl);
            tabItemViews[i] = cell;

            if (idx == TAB_HOME) {
                bindDiscoverTabGestures(cell);
            } else {
                UiWidgets.bindTouchFeedback(cell);
                cell.setOnClickListener(v -> switchTab(idx));
            }
            mainCapsule.addView(cell, new LinearLayout.LayoutParams(-2, -2));
        }

        if (compactFlat) {
            // Compact mode puts Search inside the single capsule as the 5th item
            LinearLayout sCell = a.vertical();
            sCell.setGravity(Gravity.CENTER);
            sCell.setPadding(a.dp(14), a.dp(6), a.dp(14), a.dp(6));
            NavIconView sIcon = new NavIconView(a, NavIconView.KIND_SEARCH);
            sIcon.setIconColor(activeTab == TAB_SEARCH ? accent : 0xffe5e7eb);
            sCell.addView(sIcon, new LinearLayout.LayoutParams(a.dp(21), a.dp(21)));
            TextView sLbl =
                    a.text("搜索", 10.5f, activeTab == TAB_SEARCH ? accent : MainActivity.MUTED);
            sLbl.setPadding(0, a.dp(2), 0, 0);
            sCell.addView(sLbl);
            UiWidgets.bindTouchFeedback(sCell);
            sCell.setOnClickListener(v -> switchTab(TAB_SEARCH));
            mainCapsule.addView(sCell, new LinearLayout.LayoutParams(-2, -2));
        }
        outer.addView(mainCapsule, new LinearLayout.LayoutParams(-2, -2));

        // 2. Collapsed mini pill (shown when NAV_SCROLL_BEHAVIOR == 1 and scrolling down)
        TextView miniExpand = a.text("☰ 菜单", 12.5f, Color.WHITE);
        miniExpand.setTypeface(null, Typeface.BOLD);
        miniExpand.setGravity(Gravity.CENTER);
        miniExpand.setPadding(a.dp(16), a.dp(12), a.dp(16), a.dp(12));
        miniExpand.setBackground(
                UiWidgets.glassBg(0xde1c2522, 0xe8111715, a.dp(999), a.dp(1f), 0x44ffffff));
        UiCompat.setElevation(miniExpand, a.dp(12));
        miniExpand.setVisibility(View.GONE);
        UiWidgets.bindTouchFeedback(miniExpand);
        miniExpand.setOnClickListener(v -> expandDock());
        collapsedPill = miniExpand;
        outer.addView(miniExpand, new LinearLayout.LayoutParams(-2, -2));

        // 3. Detached "+1" circular Liquid Glass Search button on the right
        if (!compactFlat) {
            FrameLayout sWrap = new FrameLayout(a);
            sWrap.setTag("mobile-nav-search");
            sWrap.setBackground(
                    activeTab == TAB_SEARCH
                            ? a.bg(accent, 999)
                            : UiWidgets.glassBg(
                                    solid ? 0xf818201e : 0xde1e2824,
                                    solid ? 0xf8101614 : 0xe6131a18,
                                    a.dp(999),
                                    a.dp(1f),
                                    0x48ffffff));
            UiCompat.setElevation(sWrap, a.dp(12));
            NavIconView sGlyph = new NavIconView(a, NavIconView.KIND_SEARCH);
            sGlyph.setIconColor(activeTab == TAB_SEARCH ? 0xff09110e : Color.WHITE);
            sWrap.addView(sGlyph, new FrameLayout.LayoutParams(a.dp(22), a.dp(22), Gravity.CENTER));
            UiWidgets.bindTouchFeedback(sWrap);
            sWrap.setOnClickListener(v -> switchTab(TAB_SEARCH));
            LinearLayout.LayoutParams sLp = new LinearLayout.LayoutParams(a.dp(52), a.dp(52));
            sLp.leftMargin = a.dp(10);
            outer.addView(sWrap, sLp);
            searchBubble = sWrap;
        }
        return outer;
    }

    private LinearLayout buildVerticalSideRail() {
        LinearLayout rail = a.vertical();
        rail.setGravity(Gravity.CENTER_HORIZONTAL);
        rail.setPadding(a.dp(6), a.dp(10), a.dp(6), a.dp(10));
        rail.setBackground(
                UiWidgets.glassBg(0xde1c2522, 0xe8111715, a.dp(28), a.dp(1f), 0x38ffffff));
        int[] icons = {
            NavIconView.KIND_DISCOVER,
            NavIconView.KIND_LIVE,
            NavIconView.KIND_LIBRARY,
            NavIconView.KIND_SETTINGS,
            NavIconView.KIND_SEARCH
        };
        String[] labels = {"发现", "直播", "片库", "设置", "搜索"};
        for (int i = 0; i < 5; i++) {
            final int tabIdx = i;
            LinearLayout cell = a.vertical();
            cell.setGravity(Gravity.CENTER);
            cell.setPadding(a.dp(6), a.dp(8), a.dp(6), a.dp(8));
            NavIconView icon = new NavIconView(a, icons[i]);
            if (i < 4) tabIconViews[i] = icon;
            cell.addView(icon, new LinearLayout.LayoutParams(a.dp(22), a.dp(22)));
            TextView lbl = a.text(labels[i], 10f, MainActivity.MUTED);
            lbl.setPadding(0, a.dp(2), 0, 0);
            if (i < 4) tabLabelViews[i] = lbl;
            cell.addView(lbl);
            if (i < 4) tabItemViews[i] = cell;
            if (tabIdx == TAB_HOME) {
                bindDiscoverTabGestures(cell);
            } else {
                UiWidgets.bindTouchFeedback(cell);
                cell.setOnClickListener(v -> switchTab(tabIdx));
            }
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
            if (i < 4) lp.bottomMargin = a.dp(6);
            rail.addView(cell, lp);
        }
        return rail;
    }

    /** Tap switches to Home; drag-up or long-press opens quick Source & Home-Mode switcher! */
    private void bindDiscoverTabGestures(final View view) {
        final float[] downY = {0f};
        final boolean[] triggeredSwipe = {false};
        view.setOnLongClickListener(
                v -> {
                    showQuickSourceAndModeSheet();
                    return true;
                });
        view.setOnTouchListener(
                (v, ev) -> {
                    int act = ev.getActionMasked();
                    if (act == MotionEvent.ACTION_DOWN) {
                        downY[0] = ev.getRawY();
                        triggeredSwipe[0] = false;
                        v.setAlpha(0.75f);
                    } else if (act == MotionEvent.ACTION_MOVE) {
                        if (!triggeredSwipe[0] && downY[0] - ev.getRawY() > a.dp(28)) {
                            triggeredSwipe[0] = true;
                            v.setAlpha(1f);
                            showQuickSourceAndModeSheet();
                            return true;
                        }
                    } else if (act == MotionEvent.ACTION_UP || act == MotionEvent.ACTION_CANCEL) {
                        v.setAlpha(1f);
                        if (triggeredSwipe[0]) return true;
                    }
                    return false;
                });
        view.setOnClickListener(
                v -> {
                    if (activeTab == TAB_HOME) {
                        // Tapping active Home tab again also offers quick reload / source sheet
                        switchTab(TAB_HOME);
                    } else {
                        switchTab(TAB_HOME);
                    }
                });
    }

    void showQuickSourceAndModeSheet() {
        int curMode = a.mobilePrefs().getInt(Prefs.HOME_MODE, 0);
        final List<String> labels = new ArrayList<>();
        final List<Runnable> actions = new ArrayList<>();
        int selectedIdx = 0;

        labels.add((curMode == 1 ? "★ " : "") + "TMDB 全球趋势推荐首页");
        if (curMode == 1) selectedIdx = 0;
        actions.add(
                () -> {
                    a.mobilePrefs().edit().putInt(Prefs.HOME_MODE, 1).apply();
                    switchTab(TAB_HOME);
                });

        if (a.config != null && !a.config.sites.isEmpty()) {
            for (final Cms.Site s : a.config.sites) {
                if (!a.available(s)) continue;
                boolean isCur = curMode == 0 && activeSite != null && s.key.equals(activeSite.key);
                if (isCur) selectedIdx = labels.size();
                labels.add("片源 · " + s.name);
                actions.add(
                        () -> {
                            a.mobilePrefs().edit().putInt(Prefs.HOME_MODE, 0).apply();
                            a.prefs.edit().putString(Prefs.SELECTED_SITE, s.key).apply();
                            activeSite = s;
                            switchTab(TAB_HOME);
                        });
            }
            if (a.config.depots != null && a.config.depots.length() > 1) {
                labels.add("⇄ 切换多仓仓库 (" + a.config.depots.length() + " 个子仓)");
                actions.add(() -> SourcePicker.showWarehouses(a));
            }
        }
        labels.add("＋ 导入或更新配置源");
        actions.add(() -> UiWidgets.showMobileImportDialog(a));

        UiWidgets.showDrawerPicker(
                a,
                "快速切换首页与片源",
                "提示：按住底栏「发现」图标上滑可随时呼出此面板",
                labels.toArray(new String[0]),
                selectedIdx,
                idx -> {
                    if (idx >= 0 && idx < actions.size()) actions.get(idx).run();
                });
    }

    void switchTab(int index) {
        activeTab = index;
        MobileShell.syncFromRootTab(index);
        expandDock();
        a.cancelPageRequests();
        int accent = a.mobileAccentColor();

        for (int i = 0; i < 4; i++) {
            boolean sel = (i == index);
            if (tabItemViews[i] != null) {
                tabItemViews[i].setBackground(
                        sel
                                ? UiWidgets.glassBg(
                                        (accent & 0x00ffffff) | 0x36000000,
                                        (accent & 0x00ffffff) | 0x1e000000,
                                        a.dp(999),
                                        a.dp(0.8f),
                                        (accent & 0x00ffffff) | 0x66000000)
                                : null);
            }
            if (tabIconViews[i] != null) {
                tabIconViews[i].setIconColor(sel ? accent : 0xffd4d4d8);
            }
            if (tabLabelViews[i] != null) {
                tabLabelViews[i].setTextColor(sel ? Color.WHITE : MainActivity.MUTED);
                tabLabelViews[i].setTypeface(null, sel ? Typeface.BOLD : Typeface.NORMAL);
            }
        }
        if (searchBubble instanceof FrameLayout) {
            FrameLayout sb = (FrameLayout) searchBubble;
            boolean sSel = (index == TAB_SEARCH);
            sb.setBackground(
                    sSel
                            ? a.bg(accent, 999)
                            : UiWidgets.glassBg(
                                    a.isReducedTransparency() ? 0xf818201e : 0xde1e2824,
                                    a.isReducedTransparency() ? 0xf8101614 : 0xe6131a18,
                                    a.dp(999),
                                    a.dp(1f),
                                    0x48ffffff));
            if (sb.getChildCount() > 0 && sb.getChildAt(0) instanceof NavIconView) {
                ((NavIconView) sb.getChildAt(0)).setIconColor(sSel ? 0xff09110e : Color.WHITE);
            }
        }

        if (contentContainer == null) return;
        contentContainer.removeAllViews();
        resolveActiveSite();

        switch (index) {
            case TAB_LIVE:
                MobileLivePage.render(this, contentContainer);
                break;
            case TAB_LIBRARY:
                MobileLibraryPage.render(this, contentContainer);
                break;
            case TAB_SETTINGS:
                MobileSettingsScreen.render(this, contentContainer);
                break;
            case TAB_SEARCH:
                MobileSearchPage.render(this, contentContainer);
                break;
            case TAB_HOME:
            default:
                MobileHomePage.render(this, contentContainer);
                break;
        }
    }

    /** Ambient background canvas supporting custom wallpaper + dim or dynamic cover tint glow. */
    static final class AmbientCanvasView extends View {
        private final MainActivity a;
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private int dynamicTint = 0xff112e24;
        private Bitmap wallpaper;
        private boolean wallpaperChecked;

        AmbientCanvasView(MainActivity activity) {
            super(activity);
            this.a = activity;
            this.dynamicTint = (activity.mobileAccentColor() & 0x00ffffff) | 0xff000000;
        }

        void setDynamicTint(int color) {
            if (this.dynamicTint != color) {
                this.dynamicTint = color;
                invalidate();
            }
        }

        private void ensureWallpaper() {
            if (wallpaperChecked) return;
            wallpaperChecked = true;
            if (!a.prefs.getBoolean(Prefs.WALLPAPER_ENABLED, false)) return;
            File f = new File(a.getFilesDir(), "wallpaper.jpg");
            if (f.exists()) {
                try {
                    wallpaper = BitmapFactory.decodeFile(f.getAbsolutePath());
                } catch (Throwable ignored) {
                }
            }
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            ensureWallpaper();
            if (wallpaper != null && !wallpaper.isRecycled()) {
                RectF dst = new RectF(0, 0, w, h);
                canvas.drawBitmap(wallpaper, null, dst, paint);
                int dim = Prefs.clampWallpaperDim(a.prefs.getInt(Prefs.WALLPAPER_DIM, 65));
                int alpha = Math.round(255 * (dim / 100f));
                canvas.drawColor((alpha << 24) | 0x060908);
                return;
            }
            paint.setShader(
                    new LinearGradient(
                            0,
                            0,
                            0,
                            h,
                            new int[] {0xff0b1311, 0xff070b0a, 0xff050807},
                            null,
                            Shader.TileMode.CLAMP));
            canvas.drawRect(0, 0, w, h, paint);

            if (a.mobilePrefs().getBoolean(Prefs.COVER_AMBIENT, true)) {
                int glow = (dynamicTint & 0x00ffffff) | 0x42000000;
                paint.setShader(
                        new RadialGradient(
                                w * 0.5f,
                                h * 0.12f,
                                Math.max(w, h) * 0.62f,
                                new int[] {glow, 0x00000000},
                                null,
                                Shader.TileMode.CLAMP));
                canvas.drawRect(0, 0, w, h, paint);
            }
            paint.setShader(null);
        }
    }

    /** Crisp vector icon glyphs for the 5 mobile navigation entries. */
    static final class NavIconView extends View {
        static final int KIND_DISCOVER = 0;
        static final int KIND_LIVE = 1;
        static final int KIND_LIBRARY = 2;
        static final int KIND_SETTINGS = 3;
        static final int KIND_SEARCH = 4;

        private final MainActivity a;
        private final int kind;
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private int iconColor = Color.WHITE;

        NavIconView(MainActivity activity, int kind) {
            super(activity);
            this.a = activity;
            this.kind = kind;
        }

        void setIconColor(int color) {
            if (this.iconColor != color) {
                this.iconColor = color;
                invalidate();
            }
        }

        @Override
        protected void onDraw(Canvas c) {
            float w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            float cx = w / 2f, cy = h / 2f;
            paint.setStyle(Paint.Style.STROKE);
            paint.setColor(iconColor);
            paint.setStrokeWidth(a.dp(1.8f));
            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setStrokeJoin(Paint.Join.ROUND);

            switch (kind) {
                case KIND_DISCOVER:
                    c.drawCircle(cx, cy, w * 0.40f, paint);
                    Path needle = new Path();
                    needle.moveTo(cx + w * 0.16f, cy - h * 0.16f);
                    needle.lineTo(cx + w * 0.05f, cy + h * 0.05f);
                    needle.lineTo(cx - w * 0.16f, cy + h * 0.16f);
                    needle.lineTo(cx - w * 0.05f, cy - h * 0.05f);
                    needle.close();
                    c.drawPath(needle, paint);
                    break;
                case KIND_LIVE:
                    c.drawRoundRect(
                            new RectF(w * 0.12f, h * 0.28f, w * 0.88f, h * 0.86f),
                            a.dp(3),
                            a.dp(3),
                            paint);
                    c.drawLine(cx - w * 0.22f, h * 0.10f, cx, h * 0.28f, paint);
                    c.drawLine(cx + w * 0.22f, h * 0.10f, cx, h * 0.28f, paint);
                    break;
                case KIND_LIBRARY:
                    c.drawRoundRect(
                            new RectF(w * 0.14f, h * 0.18f, w * 0.86f, h * 0.84f),
                            a.dp(3),
                            a.dp(3),
                            paint);
                    c.drawLine(w * 0.32f, h * 0.44f, w * 0.68f, h * 0.44f, paint);
                    c.drawLine(w * 0.32f, h * 0.64f, w * 0.56f, h * 0.64f, paint);
                    break;
                case KIND_SETTINGS:
                    c.drawCircle(cx, cy, w * 0.20f, paint);
                    c.drawCircle(cx, cy, w * 0.40f, paint);
                    break;
                case KIND_SEARCH:
                default:
                    c.drawCircle(cx - w * 0.06f, cy - h * 0.06f, w * 0.30f, paint);
                    c.drawLine(cx + w * 0.16f, cy + h * 0.16f, w * 0.86f, h * 0.86f, paint);
                    break;
            }
        }
    }
}
