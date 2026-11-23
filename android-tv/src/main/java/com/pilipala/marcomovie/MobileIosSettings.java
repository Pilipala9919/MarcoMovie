package com.pilipala.marcomovie;

import android.content.SharedPreferences;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.animation.DecelerateInterpolator;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.TextView;
import com.pilipala.glass.GlassworkSurface;
import com.pilipala.marcomovie.hud.PlayerHudPrefs;
import java.io.File;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * Android Mobile 2-Level Liquid Glass Settings architecture aligned with iOS {@code IosSettingsPage}:
 * - Level 1: Full-screen "设置" page with version subtitle (5-tap PrivacySpace) and 6 {@code 36dp}
 *   Liquid Glass category capsules
 * - Level 2: Full-screen secondary settings page (never a popup dialog) with top {@code ‹} back
 *   navigation, grouped section cards, wrapping {@code SettingsChoices} pills, and live glass slider.
 */
final class MobileIosSettings {
    private static final int COLOR_PURPLE = 0xffbf5af2;
    private static final int COLOR_BLUE = 0xff0a84ff;
    private static final int COLOR_ORANGE = 0xffff9f0a;
    private static final int COLOR_GREEN = 0xff30d158;
    private static final int COLOR_TEAL = 0xff5ac8fa;
    private static final int COLOR_INDIGO = 0xff5e5ce6;
    private static final int COLOR_CORAL = 0xffff6b4a;

    private static final int ICON_SPARKLES = 1;
    private static final int ICON_GRID = 2;
    private static final int ICON_PLAY_CIRCLE = 3;
    private static final int ICON_LAYERS = 4;
    private static final int ICON_TRAY = 5;
    private static final int ICON_INFO = 6;
    private static final int ICON_WALLPAPER = 7;
    private static final int ICON_DROPLET = 8;
    private static final int ICON_POSTER = 9;
    private static final int ICON_HOME_MODULE = 10;
    private static final int ICON_DISPLAY = 11;
    private static final int ICON_SPEED = 12;
    private static final int ICON_SKIP = 13;
    private static final int ICON_CLOUD = 14;
    private static final int ICON_BACKUP = 15;
    private static final int ICON_BROOM = 16;

    /** Empty string = Level 1 root page; non-empty = active Level 2 category title. */
    private static String activeCategoryTitle = "";

    private MobileIosSettings() {}

    static boolean hasSubPage() {
        return activeCategoryTitle != null && !activeCategoryTitle.isEmpty();
    }

    static void resetToRoot() {
        activeCategoryTitle = "";
        MobileShell.settingsSubPage = 0;
    }

    static boolean navigateBack(MainActivity a) {
        if (!hasSubPage()) return false;
        resetToRoot();
        if (a != null) {
            if (a.current != null && a.current.mobileHome != null) {
                a.current.mobileHome.refreshSettingsPage(-1);
            } else {
                MobileShell.show(a);
            }
        }
        return true;
    }

    static final class PaneSpec {
        final String title;
        final String subtitle;
        final int iconKind;
        final int color;
        final List<PaneSpec> children = new ArrayList<>();
        final PaneBuilder builder;

        PaneSpec(String title, String subtitle, int iconKind, int color, PaneBuilder builder) {
            this.title = title;
            this.subtitle = subtitle;
            this.iconKind = iconKind;
            this.color = color;
            this.builder = builder;
        }

        PaneSpec addChild(PaneSpec child) {
            children.add(child);
            return this;
        }
    }

    interface PaneBuilder {
        void build(LinearLayout body, PageController ctl);
    }

    interface ChoiceAction {
        void onSelect(int index);
    }

    static final class PageController {
        final MainActivity a;
        final FrameLayout contentContainer;
        final Cms.Site currentSite;
        final MobileShell shell;
        ScrollView activeScroll;

        PageController(
                MainActivity a,
                FrameLayout contentContainer,
                Cms.Site currentSite,
                MobileShell shell) {
            this.a = a;
            this.contentContainer = contentContainer;
            this.currentSite = currentSite;
            this.shell = shell;
        }

        void openSubPage(PaneSpec pane) {
            activeCategoryTitle = pane.title;
            MobileShell.settingsSubPage = 1;
            renderInternal(a, contentContainer, currentSite, shell, 1, 0);
        }

        void backToRoot() {
            resetToRoot();
            renderInternal(a, contentContainer, currentSite, shell, -1, 0);
        }

        void rerenderInPlace() {
            final int savedScrollY = activeScroll != null ? activeScroll.getScrollY() : 0;
            if (shell != null) shell.applyAppearancePreferences();
            renderInternal(a, contentContainer, currentSite, shell, 0, savedScrollY);
        }
    }

    static void render(
            final MainActivity a,
            final FrameLayout contentContainer,
            final Cms.Site currentSite,
            final MobileShell shell) {
        render(a, contentContainer, currentSite, shell, 0);
    }

    static void render(
            final MainActivity a,
            final FrameLayout contentContainer,
            final Cms.Site currentSite,
            final MobileShell shell,
            final int slideDirection) {
        renderInternal(a, contentContainer, currentSite, shell, slideDirection, 0);
    }

    private static void renderInternal(
            final MainActivity a,
            final FrameLayout contentContainer,
            final Cms.Site currentSite,
            final MobileShell shell,
            final int slideDirection,
            final int restoreScrollY) {
        contentContainer.removeAllViews();

        final ScrollView sv = new ScrollView(a);
        sv.setVerticalScrollBarEnabled(false);
        sv.setClipToPadding(false);
        int topInset = getStatusBarHeight(a);
        int bottomDockClearance = a.dp(116) + a.navigationBarHeight();
        sv.setPadding(a.dp(20), topInset + a.dp(14), a.dp(20), bottomDockClearance);
        contentContainer.addView(sv, new FrameLayout.LayoutParams(-1, -1));

        final LinearLayout rootCol = a.vertical();
        sv.addView(rootCol, new ScrollView.LayoutParams(-1, -2));

        final PageController ctl = new PageController(a, contentContainer, currentSite, shell);
        ctl.activeScroll = sv;

        List<PaneSpec> pages = buildPages(a, currentSite, shell);
        PaneSpec activePane = null;
        if (hasSubPage()) {
            for (PaneSpec p : pages) {
                if (p.title.equals(activeCategoryTitle)) {
                    activePane = p;
                    break;
                }
            }
            if (activePane == null) {
                resetToRoot();
            }
        }
        MobileShell.settingsSubPage = activePane != null ? 1 : 0;

        if (!a.isTvDevice() && activePane != null && "关于与更新".equals(activePane.title)) {
            AuroraSurfaceView aurora = new AuroraSurfaceView(a);
            aurora.setReducedMotion(a.reduced);
            contentContainer.addView(aurora, 0, new FrameLayout.LayoutParams(-1, -1));
        }

        if (activePane == null) {
            // ==================== LEVEL 1: PRIMARY SETTINGS PAGE ====================
            TextView largeTitle = a.text("设置", 32f, 0xfff5f5f7);
            largeTitle.setTypeface(null, Typeface.BOLD);
            largeTitle.setLetterSpacing(-0.02f);
            rootCol.addView(largeTitle, new LinearLayout.LayoutParams(-1, -2));

            a.gap(rootCol, 6);

            String verText = "Marco Movie · v" + UpdateManager.installedVersion(a);
            if (a.privateMode) verText += " · 隐私空间";
            TextView verLabel = a.text(verText, 13f, a.privateMode ? COLOR_GREEN : 0xffd1d1da);
            verLabel.setOnClickListener(v -> PrivacySpace.logoTap(a));
            rootCol.addView(verLabel, new LinearLayout.LayoutParams(-1, -2));

            a.gap(rootCol, 22);

            int widthPx = a.windowWidth();
            float density = a.getResources().getDisplayMetrics().density;
            boolean twoCols = (widthPx / Math.max(1f, density)) >= 620f;

            if (!twoCols) {
                for (int i = 0; i < pages.size(); i++) {
                    final PaneSpec pane = pages.get(i);
                    View cap = buildSettingsCapsule(a, pane, () -> ctl.openSubPage(pane));
                    LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
                    lp.bottomMargin = a.dp(12);
                    rootCol.addView(cap, lp);
                }
            } else {
                for (int i = 0; i < pages.size(); i += 2) {
                    LinearLayout row = a.row();
                    row.setGravity(Gravity.TOP);
                    final PaneSpec leftPane = pages.get(i);
                    View leftCap =
                            buildSettingsCapsule(a, leftPane, () -> ctl.openSubPage(leftPane));
                    LinearLayout.LayoutParams leftLp = new LinearLayout.LayoutParams(0, -2, 1f);
                    leftLp.rightMargin = a.dp(7);
                    row.addView(leftCap, leftLp);

                    if (i + 1 < pages.size()) {
                        final PaneSpec rightPane = pages.get(i + 1);
                        View rightCap =
                                buildSettingsCapsule(
                                        a, rightPane, () -> ctl.openSubPage(rightPane));
                        LinearLayout.LayoutParams rightLp =
                                new LinearLayout.LayoutParams(0, -2, 1f);
                        rightLp.leftMargin = a.dp(7);
                        row.addView(rightCap, rightLp);
                    } else {
                        LinearLayout.LayoutParams emptyLp = new LinearLayout.LayoutParams(0, 1, 1f);
                        emptyLp.leftMargin = a.dp(7);
                        row.addView(new View(a), emptyLp);
                    }
                    LinearLayout.LayoutParams rowLp = new LinearLayout.LayoutParams(-1, -2);
                    rowLp.bottomMargin = a.dp(12);
                    rootCol.addView(row, rowLp);
                }
            }
        } else {
            // ==================== LEVEL 2: SECONDARY SETTINGS PAGE ====================
            LinearLayout topNav = a.row();
            topNav.setGravity(Gravity.CENTER_VERTICAL);
            topNav.setPadding(0, 0, 0, a.dp(12));

            TextView backBtn = a.text("‹", 22f, Color.WHITE);
            backBtn.setTag("settings-back");
            backBtn.setGravity(Gravity.CENTER);
            backBtn.setPadding(0, 0, a.dp(1), a.dp(2));
            GradientDrawable backCircle = new GradientDrawable();
            backCircle.setShape(GradientDrawable.OVAL);
            backCircle.setColor(0x24ffffff);
            backCircle.setStroke(Math.max(1, a.dp(1)), 0x34ffffff);
            backBtn.setBackground(backCircle);
            bindPressFeedback(backBtn);
            backBtn.setOnClickListener(v -> ctl.backToRoot());
            LinearLayout.LayoutParams backLp = new LinearLayout.LayoutParams(a.dp(38), a.dp(38));
            backLp.rightMargin = a.dp(12);
            topNav.addView(backBtn, backLp);

            LinearLayout titleStack = a.vertical();
            TextView crumb = a.text("设置", 11.5f, 0x99ebebf5);
            crumb.setOnClickListener(v -> ctl.backToRoot());
            titleStack.addView(crumb);

            TextView subTitle = a.text(activePane.title, 24f, 0xfff5f5f7);
            subTitle.setTypeface(null, Typeface.BOLD);
            titleStack.addView(subTitle);
            topNav.addView(titleStack, new LinearLayout.LayoutParams(0, -2, 1f));
            rootCol.addView(topNav, new LinearLayout.LayoutParams(-1, -2));

            if (activePane.subtitle != null && !activePane.subtitle.isEmpty()) {
                TextView desc = a.text(activePane.subtitle, 13f, 0xffd1d1da);
                desc.setLineSpacing(a.dp(3), 1f);
                desc.setPadding(a.dp(2), 0, a.dp(2), a.dp(16));
                rootCol.addView(desc, new LinearLayout.LayoutParams(-1, -2));
            }

            if (!activePane.children.isEmpty()) {
                for (int i = 0; i < activePane.children.size(); i++) {
                    PaneSpec section = activePane.children.get(i);
                    addSubSectionCard(a, rootCol, section, ctl);
                }
            }
            if (activePane.builder != null) {
                activePane.builder.build(rootCol, ctl);
            }
        }

        if (restoreScrollY > 0) {
            sv.post(() -> sv.scrollTo(0, restoreScrollY));
        }
        if (slideDirection != 0 && !a.reduced) {
            rootCol.setTranslationX(slideDirection > 0 ? a.dp(26) : -a.dp(22));
            rootCol.setAlpha(0.35f);
            rootCol.animate()
                    .translationX(0f)
                    .alpha(1f)
                    .setDuration(170)
                    .setInterpolator(new DecelerateInterpolator())
                    .start();
        }
    }

    private static void addSubSectionCard(
            MainActivity a, LinearLayout parent, PaneSpec section, PageController ctl) {
        LinearLayout card = a.vertical();
        card.setPadding(a.dp(16), a.dp(16), a.dp(16), a.dp(10));
        int intensity = a.prefs.getInt(Prefs.MOBILE_GLASS_INTENSITY, 65);
        int fillAlpha = Math.round(0x12 + (intensity / 100f) * 0x14);
        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.RECTANGLE);
        bg.setCornerRadius(a.dp(28));
        bg.setColor((fillAlpha << 24) | 0x00ffffff);
        bg.setStroke(Math.max(1, a.dp(1)), 0x22ffffff);
        card.setBackground(bg);

        LinearLayout secHeader = a.row();
        secHeader.setGravity(Gravity.CENTER_VERTICAL);

        FrameLayout badge = new FrameLayout(a);
        GradientDrawable circle = new GradientDrawable();
        circle.setShape(GradientDrawable.OVAL);
        circle.setColor((section.color & 0x00ffffff) | 0x2e000000);
        badge.setBackground(circle);
        badge.addView(
                new CapsuleIconView(a, section.iconKind, section.color),
                new FrameLayout.LayoutParams(a.dp(18), a.dp(18), Gravity.CENTER));
        LinearLayout.LayoutParams badgeLp = new LinearLayout.LayoutParams(a.dp(32), a.dp(32));
        badgeLp.rightMargin = a.dp(10);
        secHeader.addView(badge, badgeLp);

        LinearLayout secTitles = a.vertical();
        TextView st = a.text(section.title, 16f, 0xfff5f5f7);
        st.setTypeface(null, Typeface.BOLD);
        secTitles.addView(st);
        if (section.subtitle != null && !section.subtitle.isEmpty()) {
            TextView ss = a.text(section.subtitle, 11.5f, 0xb8d1d1da);
            ss.setPadding(0, a.dp(2), 0, 0);
            secTitles.addView(ss);
        }
        secHeader.addView(secTitles, new LinearLayout.LayoutParams(0, -2, 1f));
        card.addView(secHeader, new LinearLayout.LayoutParams(-1, -2));

        a.gap(card, 14);
        if (section.builder != null) {
            section.builder.build(card, ctl);
        }

        LinearLayout.LayoutParams cardLp = new LinearLayout.LayoutParams(-1, -2);
        cardLp.bottomMargin = a.dp(14);
        parent.addView(card, cardLp);
    }

    private static List<PaneSpec> buildPages(
            final MainActivity a, final Cms.Site currentSite, final MobileShell shell) {
        List<PaneSpec> top = new ArrayList<>();

        // 1. 外观 (Sparkles, #BF5AF2)
        PaneSpec wallpaperSub =
                new PaneSpec(
                        "壁纸与氛围",
                        "切换应用背景壁纸、呼吸流光与界面显示比例",
                        ICON_WALLPAPER,
                        COLOR_PURPLE,
                        (body, ctl) -> {
                            final boolean wpEnabled =
                                    a.prefs.getBoolean(Prefs.WALLPAPER_ENABLED, false);
                            final boolean hasSavedWp =
                                    new File(a.getFilesDir(), "wallpaper.jpg").exists();
                            addChoices(
                                    a,
                                    body,
                                    "应用背景模式",
                                    hasSavedWp
                                            ? new String[] {"深色流光背景", "启用已存壁纸", "相册选图…", "图片网址…"}
                                            : new String[] {"深色流光背景", "相册选图…", "图片网址…"},
                                    wpEnabled && hasSavedWp ? 1 : 0,
                                    idx -> {
                                        if (idx == 0) {
                                            a.prefs
                                                    .edit()
                                                    .putBoolean(Prefs.WALLPAPER_ENABLED, false)
                                                    .apply();
                                            ctl.rerenderInPlace();
                                        } else if (hasSavedWp && idx == 1) {
                                            a.prefs
                                                    .edit()
                                                    .putBoolean(Prefs.WALLPAPER_ENABLED, true)
                                                    .apply();
                                            ctl.rerenderInPlace();
                                        } else if ((hasSavedWp && idx == 2)
                                                || (!hasSavedWp && idx == 1)) {
                                            new SettingsScreen(a).pick(44, "image/*", false);
                                        } else {
                                            new SettingsScreen(a).wallpaperUrl();
                                        }
                                    });

                            int curDim = a.prefs.getInt(Prefs.WALLPAPER_DIM, 60);
                            int dimIdx = curDim <= 45 ? 0 : (curDim >= 75 ? 2 : 1);
                            final int[] dimVals = {40, 60, 80};
                            addChoices(
                                    a,
                                    body,
                                    "壁纸遮罩压暗",
                                    new String[] {"轻柔 40%", "标准 60%", "深邃 80%"},
                                    dimIdx,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putInt(Prefs.WALLPAPER_DIM, dimVals[idx])
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            boolean ambient = a.prefs.getBoolean(Prefs.HOME_AMBIENT, true);
                            addChoices(
                                    a,
                                    body,
                                    "呼吸式氛围流光",
                                    new String[] {"开启", "关闭"},
                                    ambient ? 0 : 1,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putBoolean(Prefs.HOME_AMBIENT, idx == 0)
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            boolean startupAnim = a.prefs.getBoolean(Prefs.STARTUP_ANIMATION, true);
                            addChoices(
                                    a,
                                    body,
                                    "启动开屏动画",
                                    new String[] {"开启", "关闭"},
                                    startupAnim ? 0 : 1,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putBoolean(Prefs.STARTUP_ANIMATION, idx == 0)
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            boolean reducedMotion = a.prefs.getBoolean(Prefs.REDUCED, false);
                            addChoices(
                                    a,
                                    body,
                                    "动态效果与过渡",
                                    new String[] {"标准灵动", "减少动态效果"},
                                    reducedMotion ? 1 : 0,
                                    idx -> {
                                        boolean next = (idx == 1);
                                        a.prefs.edit().putBoolean(Prefs.REDUCED, next).apply();
                                        a.reduced = next;
                                        ctl.rerenderInPlace();
                                    });

                            int uiScale = a.prefs.getInt(Prefs.UI_SCALE_PERCENT, 100);
                            final int[] scaleVals = {90, 100, 110};
                            int scaleIdx = uiScale <= 92 ? 0 : (uiScale >= 108 ? 2 : 1);
                            addChoices(
                                    a,
                                    body,
                                    "全局界面缩放",
                                    new String[] {"紧凑 90%", "标准 100%", "放大 110%"},
                                    scaleIdx,
                                    idx -> {
                                        int target = scaleVals[idx];
                                        if (target != uiScale) {
                                            a.prefs
                                                    .edit()
                                                    .putInt(Prefs.UI_SCALE_PERCENT, target)
                                                    .apply();
                                            a.recreate();
                                        }
                                    });
                        });

        PaneSpec glassSub =
                new PaneSpec(
                        "液态玻璃",
                        "实时调节导航栏、胶囊与卡片的磨砂半透明质感",
                        ICON_DROPLET,
                        COLOR_TEAL,
                        (body, ctl) -> {
                            int savedIntensity =
                                    a.prefs.getInt(
                                            Prefs.MOBILE_GLASS_INTENSITY,
                                            a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false)
                                                    ? 100
                                                    : 65);
                            addGlassSliderCard(a, body, savedIntensity, ctl);

                            int presetIdx;
                            if (savedIntensity >= 96) presetIdx = 3;
                            else if (savedIntensity >= 78) presetIdx = 2;
                            else if (savedIntensity <= 45) presetIdx = 0;
                            else presetIdx = 1;
                            final int[] presets = {35, 65, 85, 100};
                            addChoices(
                                    a,
                                    body,
                                    "快速浓度预设",
                                    new String[] {"轻盈通透", "标准玻璃", "深邃磨砂", "纯色实底"},
                                    presetIdx,
                                    idx -> {
                                        int val = presets[idx];
                                        a.prefs
                                                .edit()
                                                .putInt(Prefs.MOBILE_GLASS_INTENSITY, val)
                                                .putBoolean(Prefs.REDUCED_TRANSPARENCY, val >= 96)
                                                .apply();
                                        GlassworkSurface.invalidateBackdrop(a.root);
                                        ctl.rerenderInPlace();
                                    });
                        });

        PaneSpec appearancePane =
                new PaneSpec("外观", "壁纸、流光与液态玻璃", ICON_SPARKLES, COLOR_PURPLE, null)
                        .addChild(wallpaperSub)
                        .addChild(glassSub);
        top.add(appearancePane);

        // 2. 浏览 (Grid, #0A84FF)
        PaneSpec posterCardSub =
                new PaneSpec(
                        "海报与卡片",
                        "自定义首页网格列数密度与海报下方副标题信息",
                        ICON_POSTER,
                        COLOR_BLUE,
                        (body, ctl) -> {
                            int density = a.prefs.getInt(Prefs.MOBILE_POSTER_DENSITY, 1);
                            addChoices(
                                    a,
                                    body,
                                    "海报排布密度",
                                    new String[] {"舒展", "标准", "紧凑"},
                                    Math.max(0, Math.min(2, density)),
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putInt(Prefs.MOBILE_POSTER_DENSITY, idx)
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            int subMode = a.prefs.getInt(Prefs.MOBILE_CARD_SUBTITLE, 0);
                            addChoices(
                                    a,
                                    body,
                                    "卡片副标题内容",
                                    new String[] {"更新与备注", "年份与分类", "所属片源", "隐藏副标题"},
                                    Math.max(0, Math.min(3, subMode)),
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putInt(Prefs.MOBILE_CARD_SUBTITLE, idx)
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });
                        });

        PaneSpec homeModuleSub =
                new PaneSpec(
                        "首页模块",
                        "控制主页顶部推荐焦点卡片与历史续播横栏",
                        ICON_HOME_MODULE,
                        COLOR_INDIGO,
                        (body, ctl) -> {
                            boolean showHero = a.prefs.getBoolean(Prefs.SHOW_HERO_BANNER, true);
                            addChoices(
                                    a,
                                    body,
                                    "今日首推焦点卡片",
                                    new String[] {"显示", "隐藏"},
                                    showHero ? 0 : 1,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putBoolean(Prefs.SHOW_HERO_BANNER, idx == 0)
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            boolean showHist = a.prefs.getBoolean(Prefs.MOBILE_SHOW_HISTORY, true);
                            addChoices(
                                    a,
                                    body,
                                    "继续观看历史横栏",
                                    new String[] {"显示", "隐藏"},
                                    showHist ? 0 : 1,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putBoolean(Prefs.MOBILE_SHOW_HISTORY, idx == 0)
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });
                        });

        PaneSpec browsePane =
                new PaneSpec("浏览", "首页内容、海报与卡片信息", ICON_GRID, COLOR_BLUE, null)
                        .addChild(posterCardSub)
                        .addChild(homeModuleSub);
        top.add(browsePane);

        // 3. 播放 (Play Circle, #FF9F0A)
        PaneSpec videoQualitySub =
                new PaneSpec(
                        "画质与画面",
                        "配置播放器内核、硬解策略、HDR 画面与音轨输出",
                        ICON_DISPLAY,
                        COLOR_ORANGE,
                        (body, ctl) -> {
                            int eng = a.prefs.getInt(Prefs.PLAYER_ENGINE, 0);
                            final int[] engVals = {0, 3, 2, 1};
                            int engIdx = eng == 3 ? 1 : (eng == 2 ? 2 : (eng == 1 ? 3 : 0));
                            addChoices(
                                    a,
                                    body,
                                    "默认播放器内核",
                                    new String[] {
                                        "Exo (Media3)",
                                        "MPV 高画质 (HDR/Anime4K)",
                                        "IJK (FFmpeg)",
                                        "系统播放器"
                                    },
                                    engIdx,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putInt(Prefs.PLAYER_ENGINE, engVals[idx])
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            int dec = a.prefs.getInt(Prefs.DECODER_MODE, 0);
                            addChoices(
                                    a,
                                    body,
                                    "解码方式",
                                    new String[] {"自动选择", "硬件解码", "软件解码优先"},
                                    Math.max(0, Math.min(2, dec)),
                                    idx -> {
                                        a.prefs.edit().putInt(Prefs.DECODER_MODE, idx).apply();
                                        ctl.rerenderInPlace();
                                    });

                            int aspect = a.prefs.getInt(Prefs.ASPECT, 0);
                            addChoices(
                                    a,
                                    body,
                                    "默认画面比例",
                                    new String[] {"原始适应", "铺满屏幕", "16:9", "4:3", "裁切填充"},
                                    Math.max(0, Math.min(4, aspect)),
                                    idx -> {
                                        a.prefs.edit().putInt(Prefs.ASPECT, idx).apply();
                                        ctl.rerenderInPlace();
                                    });

                            int outMode = a.prefs.getInt(Prefs.VIDEO_OUTPUT, 0);
                            addChoices(
                                    a,
                                    body,
                                    "画面渲染输出",
                                    new String[] {"保真 HDR (Surface)", "兼容调色 (Texture)"},
                                    outMode == 1 ? 1 : 0,
                                    idx -> {
                                        a.prefs.edit().putInt(Prefs.VIDEO_OUTPUT, idx).apply();
                                        ctl.rerenderInPlace();
                                    });

                            int buf = a.prefs.getInt(Prefs.BUFFER_SECONDS, 30);
                            final int[] bufVals = {15, 30, 50};
                            int bufIdx = buf <= 20 ? 0 : (buf >= 45 ? 2 : 1);
                            addChoices(
                                    a,
                                    body,
                                    "网络预缓冲时长",
                                    new String[] {"15 秒", "30 秒", "50 秒"},
                                    bufIdx,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putInt(Prefs.BUFFER_SECONDS, bufVals[idx])
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            boolean swAudio = a.prefs.getBoolean(Prefs.SOFTWARE_AUDIO, false);
                            addChoices(
                                    a,
                                    body,
                                    "兼容音频软解",
                                    new String[] {"关闭 (默认直通)", "开启兼容软解"},
                                    swAudio ? 1 : 0,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putBoolean(Prefs.SOFTWARE_AUDIO, idx == 1)
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            boolean preferAac = a.prefs.getBoolean(Prefs.PREFER_AAC, false);
                            addChoices(
                                    a,
                                    body,
                                    "多音轨优先 AAC",
                                    new String[] {"默认音轨", "优先 AAC"},
                                    preferAac ? 1 : 0,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putBoolean(Prefs.PREFER_AAC, idx == 1)
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            boolean tunnel = a.prefs.getBoolean(Prefs.TUNNELED_PLAYBACK, false);
                            addChoices(
                                    a,
                                    body,
                                    "4K HDR 硬件隧道",
                                    new String[] {"关闭", "开启"},
                                    tunnel ? 1 : 0,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putBoolean(Prefs.TUNNELED_PLAYBACK, idx == 1)
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            boolean hdrTm = a.prefs.getBoolean(Prefs.HDR_TONE_MAPPING, true);
                            addChoices(
                                    a,
                                    body,
                                    "MPV HDR 色调映射",
                                    new String[] {"关闭", "开启 (libplacebo)"},
                                    hdrTm ? 1 : 0,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putBoolean(Prefs.HDR_TONE_MAPPING, idx == 1)
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            boolean anime4k = a.prefs.getBoolean(Prefs.ANIME4K_ENABLED, false);
                            addChoices(
                                    a,
                                    body,
                                    "MPV Anime4K 超分",
                                    new String[] {"关闭", "开启 (CNN x2)"},
                                    anime4k ? 1 : 0,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putBoolean(Prefs.ANIME4K_ENABLED, idx == 1)
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            boolean hlsProxy = a.prefs.getBoolean(Prefs.HLS_PROXY_ENABLED, true);
                            addChoices(
                                    a,
                                    body,
                                    "HLS 伪装分片修正代理",
                                    new String[] {"关闭", "开启 (推荐)"},
                                    hlsProxy ? 1 : 0,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putBoolean(Prefs.HLS_PROXY_ENABLED, idx == 1)
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            boolean hlsAdStrip = a.prefs.getBoolean(Prefs.HLS_AD_STRIP, false);
                            addChoices(
                                    a,
                                    body,
                                    "HLS 广告分段过滤",
                                    new String[] {"关闭", "开启"},
                                    hlsAdStrip ? 1 : 0,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putBoolean(Prefs.HLS_AD_STRIP, idx == 1)
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            int cacheMb = a.prefs.getInt(Prefs.MEDIA_CACHE_MB, 256);
                            final int[] cacheVals = {0, 128, 256, 512, 1024};
                            int cacheIdx = 2;
                            for (int ci = 0; ci < cacheVals.length; ci++) {
                                if (cacheVals[ci] == cacheMb) {
                                    cacheIdx = ci;
                                    break;
                                }
                            }
                            addChoices(
                                    a,
                                    body,
                                    "直链本地分块缓存",
                                    new String[] {"关闭", "128MB", "256MB", "512MB", "1GB"},
                                    cacheIdx,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putInt(Prefs.MEDIA_CACHE_MB, cacheVals[idx])
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            int loud = a.prefs.getInt(Prefs.LOUDNESS_BOOST, 0);
                            final int[] loudVals = {0, 4, 8, 12};
                            int loudIdx = 0;
                            for (int li = 0; li < loudVals.length; li++) {
                                if (loudVals[li] == loud) {
                                    loudIdx = li;
                                    break;
                                }
                            }
                            addChoices(
                                    a,
                                    body,
                                    "人声与响度增益",
                                    new String[] {"关闭", "+4dB", "+8dB", "+12dB"},
                                    loudIdx,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putInt(Prefs.LOUDNESS_BOOST, loudVals[idx])
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            boolean nativePy =
                                    a.prefs.getBoolean(Prefs.NATIVE_PYTHON_ENABLED, true);
                            addChoices(
                                    a,
                                    body,
                                    "内置 CPython 3.11 源引擎",
                                    new String[] {"关闭 (Skulpt)", "开启 (原生)"},
                                    nativePy ? 1 : 0,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putBoolean(Prefs.NATIVE_PYTHON_ENABLED, idx == 1)
                                                .apply();
                                        a.closeEngines();
                                        ctl.rerenderInPlace();
                                    });

                            boolean wvJs = a.prefs.getBoolean(Prefs.WEBVIEW_JS_FALLBACK, true);
                            addChoices(
                                    a,
                                    body,
                                    "异步 JS WebView 兜底",
                                    new String[] {"关闭", "开启 (推荐)"},
                                    wvJs ? 1 : 0,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putBoolean(Prefs.WEBVIEW_JS_FALLBACK, idx == 1)
                                                .apply();
                                        a.closeEngines();
                                        ctl.rerenderInPlace();
                                    });

                            int pic = a.prefs.getInt(Prefs.PICTURE_EFFECT, 0);
                            addChoices(
                                    a,
                                    body,
                                    "画面色彩预设",
                                    new String[] {"原始", "明亮", "影院", "柔和"},
                                    Math.max(0, Math.min(3, pic)),
                                    idx -> {
                                        a.prefs.edit().putInt(Prefs.PICTURE_EFFECT, idx).apply();
                                        ctl.rerenderInPlace();
                                    });

                            int sfx = a.prefs.getInt(Prefs.AUDIO_EFFECT, 0);
                            addChoices(
                                    a,
                                    body,
                                    "空间与人声音效",
                                    new String[] {"原声", "影院", "人声清晰", "柔和低音"},
                                    Math.max(0, Math.min(3, sfx)),
                                    idx -> {
                                        a.prefs.edit().putInt(Prefs.AUDIO_EFFECT, idx).apply();
                                        ctl.rerenderInPlace();
                                    });

                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_DISPLAY,
                                    COLOR_ORANGE,
                                    "本机解码组件报告",
                                    "查看当前设备支持的硬解与内置音频扩展",
                                    () ->
                                            new AppDialog.Builder(a)
                                                    .setTitle("解码组件")
                                                    .setMessage(DecoderSupport.description(false))
                                                    .setPositiveButton("确定", null)
                                                    .show());
                        });

        PaneSpec speedEpisodeSub =
                new PaneSpec(
                        "倍速与选集",
                        "默认起播倍速、剧集排列顺序、弹幕与字幕外观",
                        ICON_SPEED,
                        COLOR_GREEN,
                        (body, ctl) -> {
                            final String[] speedLabels = {"0.75×", "1.0×", "1.25×", "1.5×", "2.0×"};
                            final float[] speedVals = {0.75f, 1.0f, 1.25f, 1.5f, 2.0f};
                            float curSpeed = a.prefs.getFloat(Prefs.PLAY_SPEED, 1.0f);
                            int speedIdx = 1;
                            for (int i = 0; i < speedVals.length; i++) {
                                if (Math.abs(curSpeed - speedVals[i]) < 0.05f) {
                                    speedIdx = i;
                                    break;
                                }
                            }
                            addChoices(
                                    a,
                                    body,
                                    "默认起播倍速",
                                    speedLabels,
                                    speedIdx,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putFloat(Prefs.PLAY_SPEED, speedVals[idx])
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            boolean desc = a.prefs.getBoolean(Prefs.EPISODES_DESCENDING, false);
                            addChoices(
                                    a,
                                    body,
                                    "详情页剧集排序",
                                    new String[] {"正序 (第 1 集起)", "倒序 (最新集优先)"},
                                    desc ? 1 : 0,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putBoolean(Prefs.EPISODES_DESCENDING, idx == 1)
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            boolean autoNext = a.prefs.getBoolean(Prefs.AUTO_NEXT, true);
                            addChoices(
                                    a,
                                    body,
                                    "自动连播下一集",
                                    new String[] {"开启", "关闭"},
                                    autoNext ? 0 : 1,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putBoolean(Prefs.AUTO_NEXT, idx == 0)
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            int rep = a.prefs.getInt(Prefs.REPEAT_MODE, 0);
                            addChoices(
                                    a,
                                    body,
                                    "循环播放模式",
                                    new String[] {"播完停止", "单集循环", "列表循环"},
                                    Math.max(0, Math.min(2, rep)),
                                    idx -> {
                                        a.prefs.edit().putInt(Prefs.REPEAT_MODE, idx).apply();
                                        ctl.rerenderInPlace();
                                    });

                            int audioPref = a.prefs.getInt(Prefs.AUDIO_TRACK_PREFERENCE, 0);
                            addChoices(
                                    a,
                                    body,
                                    "自动音轨偏好",
                                    new String[] {"智能默认", "优先中文", "优先原声"},
                                    Math.max(0, Math.min(2, audioPref)),
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putInt(Prefs.AUDIO_TRACK_PREFERENCE, idx)
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            boolean danmaku = a.prefs.getBoolean(Prefs.DANMAKU_DEFAULT, true);
                            addChoices(
                                    a,
                                    body,
                                    "自动加载弹幕",
                                    new String[] {"开启", "关闭"},
                                    danmaku ? 0 : 1,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putBoolean(Prefs.DANMAKU_DEFAULT, idx == 0)
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            DanmuSettingsPanel.DanmuConfig dmCfg =
                                    DanmuSettingsPanel.loadConfig(a, false);
                            String dmSummary = DanmuSettingsPanel.formatConfigSummary(dmCfg);
                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_LAYERS,
                                    COLOR_TEAL,
                                    "弹幕设置",
                                    dmSummary,
                                    () -> {
                                        android.app.AlertDialog dlg =
                                                DanmuSettingsPanel.showDialog(a, false, null);
                                        dlg.setOnDismissListener(
                                                d -> {
                                                    if (!a.isFinishing()
                                                            && (android.os.Build.VERSION.SDK_INT
                                                                            < 17
                                                                    || !a.isDestroyed())) {
                                                        ctl.rerenderInPlace();
                                                    }
                                                });
                                    });

                            boolean alwaysClock =
                                    a.prefs.getBoolean(Prefs.PLAYER_ALWAYS_SHOW_CLOCK, false);
                            addChoices(
                                    a,
                                    body,
                                    "播放页常显时间",
                                    new String[] {"开启", "关闭"},
                                    alwaysClock ? 0 : 1,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putBoolean(
                                                        Prefs.PLAYER_ALWAYS_SHOW_CLOCK, idx == 0)
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            int subStyle =
                                    Prefs.clampSubtitleStyle(
                                            a.prefs.getInt(Prefs.SUBTITLE_STYLE, 0));
                            addChoices(
                                    a,
                                    body,
                                    "外挂与内封字幕样式",
                                    SubtitleOverlayView.STYLE_LABELS,
                                    subStyle,
                                    idx -> {
                                        a.prefs.edit().putInt(Prefs.SUBTITLE_STYLE, idx).apply();
                                        ctl.rerenderInPlace();
                                    });

                            int subSize =
                                    Prefs.clampSubtitleSize(
                                            a.prefs.getInt(Prefs.SUBTITLE_SIZE, 45));
                            int subBottom =
                                    Prefs.clampSubtitleBottom(
                                            a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24));
                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_DISPLAY,
                                    COLOR_BLUE,
                                    "字幕大小与位置全屏调校",
                                    "当前字号 " + subSize + " · 距底 " + subBottom + "dp (支持双指缩放与拖拽)",
                                    () ->
                                            PlaybackControls.showSubtitleAdjuster(
                                                    a, null, ctl::rerenderInPlace));
                        });

        PaneSpec hudGestureSub =
                new PaneSpec(
                        "触控手势与 HUD",
                        "自定义双击区域行为、长按倍速恢复策略、起播规格提示与底部细进度条",
                        ICON_PLAY_CIRCLE,
                        COLOR_TEAL,
                        (body, ctl) -> {
                            final String[] sideVals = {
                                PlayerHudPrefs.SIDES_SEEK_5S,
                                PlayerHudPrefs.SIDES_SEEK_10S,
                                PlayerHudPrefs.SIDES_SEEK_15S,
                                PlayerHudPrefs.SIDES_PLAY_PAUSE
                            };
                            String curSides = PlayerHudPrefs.getDoubleTapSides(a);
                            int sideIdx = 1;
                            for (int i = 0; i < sideVals.length; i++) {
                                if (sideVals[i].equals(curSides)) {
                                    sideIdx = i;
                                    break;
                                }
                            }
                            addChoices(
                                    a,
                                    body,
                                    "双击屏幕左右两侧",
                                    new String[] {"±5 秒", "±10 秒", "±15 秒", "播放 / 暂停"},
                                    sideIdx,
                                    idx -> {
                                        PlayerHudPrefs.setDoubleTapSides(a, sideVals[idx]);
                                        ctl.rerenderInPlace();
                                    });

                            final String[] centerVals = {
                                PlayerHudPrefs.CENTER_PLAY_PAUSE,
                                PlayerHudPrefs.CENTER_FULLSCREEN,
                                PlayerHudPrefs.CENTER_NONE
                            };
                            String curCenter = PlayerHudPrefs.getDoubleTapCenter(a);
                            int centerIdx = 0;
                            for (int i = 0; i < centerVals.length; i++) {
                                if (centerVals[i].equals(curCenter)) {
                                    centerIdx = i;
                                    break;
                                }
                            }
                            addChoices(
                                    a,
                                    body,
                                    "双击屏幕中央",
                                    new String[] {"播放 / 暂停", "切换横竖屏全屏", "关闭"},
                                    centerIdx,
                                    idx -> {
                                        PlayerHudPrefs.setDoubleTapCenter(a, centerVals[idx]);
                                        ctl.rerenderInPlace();
                                    });

                            String curRestore = PlayerHudPrefs.getLongPressRestoreMode(a);
                            addChoices(
                                    a,
                                    body,
                                    "长按倍速松手恢复",
                                    new String[] {"恢复长按前倍速", "固定恢复 1.0×"},
                                    PlayerHudPrefs.RESTORE_ONE_X.equals(curRestore) ? 1 : 0,
                                    idx -> {
                                        PlayerHudPrefs.setLongPressRestoreMode(
                                                a,
                                                idx == 1
                                                        ? PlayerHudPrefs.RESTORE_ONE_X
                                                        : PlayerHudPrefs.RESTORE_PREVIOUS);
                                        ctl.rerenderInPlace();
                                    });

                            boolean startSpec = PlayerHudPrefs.isStartSpecHudEnabled(a);
                            addChoices(
                                    a,
                                    body,
                                    "起播画质规格提示",
                                    new String[] {"开启", "关闭"},
                                    startSpec ? 0 : 1,
                                    idx -> {
                                        PlayerHudPrefs.setStartSpecHudEnabled(a, idx == 0);
                                        ctl.rerenderInPlace();
                                    });

                            boolean slimBar = PlayerHudPrefs.isSlimProgressEnabled(a);
                            addChoices(
                                    a,
                                    body,
                                    "隐藏工具栏底部细进度条",
                                    new String[] {"开启", "关闭"},
                                    slimBar ? 0 : 1,
                                    idx -> {
                                        PlayerHudPrefs.setSlimProgressEnabled(a, idx == 0);
                                        ctl.rerenderInPlace();
                                    });
                        });

        PaneSpec introOutroSub =
                new PaneSpec(
                        "片头与片尾",
                        "每部影片在播放页面独立保存片头片尾时间，不全局同步",
                        ICON_SKIP,
                        COLOR_CORAL,
                        (body, ctl) -> {
                            boolean countdown = PlayerHudPrefs.isSkipCountdownEnabled(a);
                            addChoices(
                                    a,
                                    body,
                                    "跳过片头片尾提示方式",
                                    new String[] {"3 秒可取消倒计时", "静默立即跳过"},
                                    countdown ? 0 : 1,
                                    idx -> {
                                        PlayerHudPrefs.setSkipCountdownEnabled(a, idx == 0);
                                        ctl.rerenderInPlace();
                                    });

                            int skipCount = PlaybackControls.countVideoSkipRecords(a);
                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_SKIP,
                                    COLOR_CORAL,
                                    "片头片尾按影片独立记录",
                                    skipCount <= 0
                                            ? "在播放页面点击「片头 / 片尾」会优先默认设为当前播放时间，仅对当前影片生效"
                                            : "已独立记录 " + skipCount + " 部影片 · 点击查看说明或清空全部记录",
                                    () ->
                                            PlaybackControls.showVideoSkipRecordsDialog(
                                                    a, ctl::rerenderInPlace));
                        });

        PaneSpec playbackPane =
                new PaneSpec("播放", "画质、倍速、手势与自动跳过", ICON_PLAY_CIRCLE, COLOR_ORANGE, null)
                        .addChild(videoQualitySub)
                        .addChild(speedEpisodeSub)
                        .addChild(hudGestureSub)
                        .addChild(introOutroSub);
        top.add(playbackPane);

        // 4. 订阅与账号 (Layers, #30D158)
        PaneSpec subscriptionPane =
                new PaneSpec(
                        "订阅与账号",
                        "片源管理、网盘扫码与配置",
                        ICON_LAYERS,
                        COLOR_GREEN,
                        (body, ctl) -> {
                            String curSiteName =
                                    currentSite != null
                                            ? currentSite.name
                                            : (a.config != null && !a.config.sites.isEmpty()
                                                    ? "已加载 " + a.config.sites.size() + " 个片源"
                                                    : "暂未导入订阅源");
                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_LAYERS,
                                    COLOR_GREEN,
                                    "切换当前默认片源",
                                    "当前：" + curSiteName,
                                    a::chooseSources);

                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_GRID,
                                    COLOR_BLUE,
                                    "片源排序与显隐管理",
                                    "置顶常用片源或隐藏不需要参与检索的站点",
                                    () -> SourcePicker.manage(a));

                            if (a.config != null && a.config.depots.length() > 1) {
                                addActionCapsule(
                                        a,
                                        body,
                                        ICON_LAYERS,
                                        COLOR_INDIGO,
                                        "切换多仓子仓库线路",
                                        "当前配置包含 " + a.config.depots.length() + " 条子仓库，点击切换",
                                        () -> SourcePicker.showWarehouses(a));
                            }

                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_TRAY,
                                    COLOR_TEAL,
                                    "导入或更新影视订阅",
                                    "支持一键读取剪贴板、输入订阅链接或选择本地包",
                                    () -> MobileShell.showMobileImportDialog(a));

                            if (a.config != null) {
                                addActionCapsule(
                                        a,
                                        body,
                                        ICON_LAYERS,
                                        COLOR_INDIGO,
                                        "已添加源 · 切换或管理多份订阅",
                                        "查看已保存的多份订阅源配置、自由切换或删除旧源",
                                        () -> SourcePicker.showSavedConfigs(a));
                            }

                            if (!a.privateMode) {
                                addActionCapsule(
                                        a,
                                        body,
                                        ICON_CLOUD,
                                        COLOR_TEAL,
                                        "多端网络同步（含订阅源配置）",
                                        CloudSyncDialog.statusSummary(a),
                                        () -> CloudSyncDialog.show(a, ctl::rerenderInPlace));
                            }

                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_PLAY_CIRCLE,
                                    COLOR_ORANGE,
                                    "导入或管理电视直播源",
                                    "支持 M3U、TXT (#genre#) 与 JSON 直播订阅地址",
                                    () -> SourceController.showLiveImportDialog(a));

                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_CLOUD,
                                    COLOR_GREEN,
                                    "我的云盘 · 扫码登录与线路",
                                    "管理夸克、UC、百度、阿里、115 等授权与解析排序",
                                    () -> AccountPanel.show(a));

                            if (!a.privateMode) {
                                addActionCapsule(
                                        a,
                                        body,
                                        ICON_CLOUD,
                                        COLOR_INDIGO,
                                        "局域网蜘蛛网关",
                                        SpiderGatewayDialog.statusSummary(a),
                                        () -> SpiderGatewayDialog.show(a, ctl::rerenderInPlace));
                            }

                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_DISPLAY,
                                    COLOR_PURPLE,
                                    "连接 Emby 媒体服务器",
                                    "直连家庭 NAS 或远程 Emby 媒体库流畅播放",
                                    () -> EmbyEngine.connect(a));

                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_CLOUD,
                                    COLOR_BLUE,
                                    "挂载 AList 网盘 / 媒体库",
                                    AlistAccounts.statusSummary(a),
                                    () -> AlistAccounts.openManager(a, ctl::rerenderInPlace));

                            if (CatPawSettings.available(a)) {
                                addActionCapsule(
                                        a,
                                        body,
                                        ICON_CLOUD,
                                        COLOR_TEAL,
                                        "CatPaw 本机引擎配置",
                                        "管理内嵌 CatPaw 服务端口与网盘凭据",
                                        () -> CatPawSettings.choose(a));
                            }

                            a.gap(body, 6);
                            boolean cspEnabled = a.prefs.getBoolean(Prefs.EXPERIMENTAL_CSP, true);
                            addChoices(
                                    a,
                                    body,
                                    "第三方扩展片源引擎",
                                    new String[] {"启用", "停用"},
                                    cspEnabled ? 0 : 1,
                                    idx -> {
                                        final boolean next = (idx == 0);
                                        if (next && !cspEnabled) {
                                            new AppDialog.Builder(a)
                                                    .setTitle("运行配置源提供的扩展？")
                                                    .setMessage("请仅启用来自你信任订阅源的扩展组件。")
                                                    .setNegativeButton("取消", null)
                                                    .setPositiveButton(
                                                            "启用",
                                                            (d, w) -> {
                                                                a.prefs
                                                                        .edit()
                                                                        .putBoolean(
                                                                                Prefs
                                                                                        .EXPERIMENTAL_CSP,
                                                                                true)
                                                                        .apply();
                                                                a.closeEngines();
                                                                ctl.rerenderInPlace();
                                                            })
                                                    .show();
                                        } else {
                                            a.prefs
                                                    .edit()
                                                    .putBoolean(Prefs.EXPERIMENTAL_CSP, next)
                                                    .apply();
                                            a.closeEngines();
                                            ctl.rerenderInPlace();
                                        }
                                    });

                            a.gap(body, 6);
                            boolean onlyHttps =
                                    a.prefs.getBoolean(Prefs.ONLY_ALLOW_HTTPS_PLUGINS, false);
                            addChoices(
                                    a,
                                    body,
                                    "仅允许 HTTPS 插件",
                                    new String[] {"停用", "启用"},
                                    onlyHttps ? 1 : 0,
                                    idx -> {
                                        final boolean next = (idx == 1);
                                        a.prefs
                                                .edit()
                                                .putBoolean(Prefs.ONLY_ALLOW_HTTPS_PLUGINS, next)
                                                .apply();
                                        a.closeEngines();
                                        ctl.rerenderInPlace();
                                    });

                            int threads = a.prefs.getInt(Prefs.SEARCH_THREADS, 6);
                            final int[] threadVals = {2, 4, 6};
                            int threadIdx = threads <= 2 ? 0 : (threads <= 4 ? 1 : 2);
                            addChoices(
                                    a,
                                    body,
                                    "多源聚合并发检索数",
                                    new String[] {"2 源 · 轻量", "4 源 · 均衡", "6 源 · 快速"},
                                    threadIdx,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putInt(Prefs.SEARCH_THREADS, threadVals[idx])
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            int timeout = a.prefs.getInt(Prefs.SEARCH_TIMEOUT, 20);
                            final int[] timeoutVals = {10, 20, 30};
                            int timeoutIdx = timeout <= 12 ? 0 : (timeout >= 25 ? 2 : 1);
                            addChoices(
                                    a,
                                    body,
                                    "单源检索等待上限",
                                    new String[] {"10 秒", "20 秒", "30 秒"},
                                    timeoutIdx,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putInt(Prefs.SEARCH_TIMEOUT, timeoutVals[idx])
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });
                        });
        top.add(subscriptionPane);

        // 5. 数据 (Tray, #5AC8FA)
        PaneSpec cloudSyncSub =
                new PaneSpec(
                        "多端网络同步",
                        "通过 WebDAV 或同局域网在手机、电脑、平板与电视间自动同步进度、收藏与公开订阅源",
                        ICON_CLOUD,
                        COLOR_BLUE,
                        (body, ctl) -> {
                            if (a.privateMode) {
                                addActionCapsule(
                                        a,
                                        body,
                                        ICON_LAYERS,
                                        COLOR_PURPLE,
                                        "隐私空间数据仅保存在本机",
                                        "当前处于独立隐私空间，不参与任何 WebDAV 或局域网同步",
                                        () -> a.toast("隐私空间已严格隔离，不会上传或覆盖同步数据"));
                                return;
                            }
                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_CLOUD,
                                    COLOR_BLUE,
                                    "配置 WebDAV 或连接局域网设备",
                                    CloudSyncDialog.statusSummary(a),
                                    () -> CloudSyncDialog.show(a, ctl::rerenderInPlace));

                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_TRAY,
                                    COLOR_TEAL,
                                    "立即执行 WebDAV 云同步",
                                    CloudSyncDialog.isConfigured(a)
                                            ? "拉取云端最新数据并合并推送本机观看记录、收藏与订阅"
                                            : "尚未填写 WebDAV 服务器信息，点击前往配置",
                                    () -> {
                                        if (CloudSyncDialog.isConfigured(a)) {
                                            CloudSyncDialog.runWebdavSync(
                                                    a, false, ctl::rerenderInPlace);
                                        } else {
                                            CloudSyncDialog.show(a, ctl::rerenderInPlace);
                                        }
                                    });

                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_DISPLAY,
                                    COLOR_GREEN,
                                    "生成本机局域网同步码 / 二维码",
                                    "无需云服务器，供同一局域网内的电视、电脑或另一台手机扫码双向合并",
                                    () ->
                                            new PhoneConfigDialog(a)
                                                    .showLanSyncReceiver(ctl::rerenderInPlace));

                            a.gap(body, 6);
                            boolean autoSync = CloudSyncDialog.isAutoEnabled(a);
                            addChoices(
                                    a,
                                    body,
                                    "观看与收藏变更后自动云同步",
                                    new String[] {"开启自动同步", "仅手动同步"},
                                    autoSync ? 0 : 1,
                                    idx -> {
                                        a.prefs
                                                .edit()
                                                .putBoolean(Prefs.WEBDAV_AUTO, idx == 0)
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });

                            boolean syncSubs = CloudSyncDialog.isSyncSubscriptionsEnabled(a);
                            boolean syncHist = CloudSyncDialog.isSyncHistoryEnabled(a);
                            int syncScopeIdx = (syncSubs && syncHist) ? 0 : (!syncSubs ? 1 : 2);
                            addChoices(
                                    a,
                                    body,
                                    "云同步内容范围",
                                    new String[] {"同步订阅源 + 进度与收藏", "仅同步进度与收藏", "仅同步订阅源（隔离观看记录）"},
                                    syncScopeIdx,
                                    idx -> {
                                        boolean nextSubs = idx != 1;
                                        boolean nextHist = idx != 2;
                                        a.prefs
                                                .edit()
                                                .putBoolean(Prefs.WEBDAV_SYNC_SUBS, nextSubs)
                                                .putBoolean(
                                                        CloudSyncDialog.PREF_WEBDAV_SYNC_HISTORY,
                                                        nextHist)
                                                .apply();
                                        ctl.rerenderInPlace();
                                    });
                        });

        PaneSpec backupRestoreSub =
                new PaneSpec(
                        "备份与恢复",
                        "导出跨设备通用的 JSON 备份包，包含订阅源、收藏片库、观看历史与偏好设置",
                        ICON_BACKUP,
                        COLOR_TEAL,
                        (body, ctl) -> {
                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_BACKUP,
                                    COLOR_TEAL,
                                    "导出备份文件",
                                    "保存 MarcoMovie-backup.json 到手机存储",
                                    () -> new SettingsScreen(a).pick(45, "application/json", true));

                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_TRAY,
                                    COLOR_BLUE,
                                    "从备份文件恢复",
                                    "选择已导出的备份包还原配置与观影记录 (不影响网盘登录)",
                                    () -> new SettingsScreen(a).pick(46, "*/*", false));
                        });

        PaneSpec cacheDiagSub =
                new PaneSpec(
                        "缓存与诊断",
                        "释放磁盘图片缓存、清理搜索词记录或查看运行诊断信息",
                        ICON_BROOM,
                        COLOR_ORANGE,
                        (body, ctl) -> {
                            long cacheBytes = computeDirBytes(a.getCacheDir());
                            String sizeText =
                                    String.format(
                                            Locale.US,
                                            "当前缓存约 %.1f MB · 清理后保留收藏、历史与云盘登录",
                                            cacheBytes / (1024.0 * 1024.0));
                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_BROOM,
                                    COLOR_ORANGE,
                                    "清理图片缓存与搜索记录",
                                    sizeText,
                                    () -> {
                                        a.images.evictAll();
                                        a.homeData.clear();
                                        a.prefs.edit().remove(Prefs.GLOBAL_SEARCH_HISTORY).apply();
                                        clearImageCacheFiles(a.getCacheDir());
                                        a.toast("已清理图片缓存与搜索记录");
                                        ctl.rerenderInPlace();
                                    });

                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_INFO,
                                    COLOR_BLUE,
                                    "查看运行诊断日志",
                                    "排查片源网络请求、扩展加载或解码器异常记录",
                                    () -> new SettingsScreen(a).diagnostics());

                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_LAYERS,
                                    COLOR_PURPLE,
                                    a.privateMode ? "退出隐私空间" : "隐私空间",
                                    a.privateMode
                                            ? "当前处于独立加密空间，点击返回常规空间"
                                            : "连续点击设置页版本号 5 次亦可快速进入独立私密空间",
                                    () -> {
                                        for (int i = 0; i < 5; i++) PrivacySpace.logoTap(a);
                                    });

                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_SKIP,
                                    COLOR_CORAL,
                                    "恢复外观与播放默认设置",
                                    "重置界面与播放器参数，保留已导入的订阅源与云盘授权",
                                    () ->
                                            new AppDialog.Builder(a)
                                                    .setTitle("恢复默认设置？")
                                                    .setMessage(
                                                            "外观与播放参数将恢复初始状态，已导入的片源、收藏与云盘登录均会保留。")
                                                    .setNegativeButton("取消", null)
                                                    .setPositiveButton(
                                                            "恢复默认",
                                                            (d, w) -> {
                                                                SharedPreferences.Editor ed =
                                                                        a.prefs.edit();
                                                                for (String k : Prefs.KEYS) {
                                                                    ed.remove(k);
                                                                }
                                                                ed.remove(
                                                                                Prefs
                                                                                        .MOBILE_GLASS_INTENSITY)
                                                                        .remove(
                                                                                Prefs
                                                                                        .MOBILE_POSTER_DENSITY)
                                                                        .remove(
                                                                                Prefs
                                                                                        .MOBILE_CARD_SUBTITLE)
                                                                        .remove(
                                                                                Prefs
                                                                                        .MOBILE_SHOW_HISTORY)
                                                                        .apply();
                                                                a.reduced = false;
                                                                resetToRoot();
                                                                a.recreate();
                                                            })
                                                    .show());
                        });

        PaneSpec dataPane =
                new PaneSpec("数据", "多端网络同步、跨平台备份与缓存清理", ICON_TRAY, COLOR_TEAL, null)
                        .addChild(cloudSyncSub)
                        .addChild(backupRestoreSub)
                        .addChild(cacheDiagSub);
        top.add(dataPane);

        // 6. 关于与更新 (Info Circle, #5E5CE6)
        PaneSpec aboutPane =
                new PaneSpec(
                        "关于与更新",
                        "版本信息与安装包下载",
                        ICON_INFO,
                        COLOR_INDIGO,
                        (body, ctl) -> {
                            LinearLayout brandCard = a.vertical();
                            brandCard.setGravity(Gravity.CENTER_HORIZONTAL);
                            brandCard.setPadding(a.dp(20), a.dp(22), a.dp(20), a.dp(20));
                            GradientDrawable cardBg = new GradientDrawable();
                            cardBg.setShape(GradientDrawable.RECTANGLE);
                            cardBg.setCornerRadius(a.dp(26));
                            cardBg.setColor(0x16ffffff);
                            cardBg.setStroke(Math.max(1, a.dp(1)), 0x22ffffff);
                            brandCard.setBackground(cardBg);

                            ImageView logo = new ImageView(a);
                            try {
                                logo.setImageResource(R.drawable.logo_mark);
                            } catch (Throwable ignored) {
                                logo.setImageResource(R.mipmap.ic_launcher);
                            }
                            logo.setScaleType(ImageView.ScaleType.FIT_CENTER);
                            brandCard.addView(
                                    logo, new LinearLayout.LayoutParams(a.dp(52), a.dp(52)));

                            a.gap(brandCard, 12);
                            TextView appName = a.text("Marco Movie", 22f, 0xfff5f5f7);
                            appName.setTypeface(null, Typeface.BOLD);
                            brandCard.addView(appName);

                            a.gap(brandCard, 4);
                            TextView ver =
                                    a.text(
                                            "当前版本 v" + UpdateManager.installedVersion(a),
                                            13f,
                                            0xffd1d1da);
                            brandCard.addView(ver);

                            LinearLayout.LayoutParams brandLp =
                                    new LinearLayout.LayoutParams(-1, -2);
                            brandLp.bottomMargin = a.dp(14);
                            body.addView(brandCard, brandLp);

                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_INFO,
                                    COLOR_INDIGO,
                                    "检查软件更新",
                                    "在线检测新版本说明、校验签名并下载安装包",
                                    () ->
                                            a.open(
                                                    new MainActivity.Screen(
                                                            () -> new UpdateScreen(a).show()),
                                                    true));

                            addActionCapsule(
                                    a,
                                    body,
                                    ICON_SPARKLES,
                                    COLOR_INDIGO,
                                    "重新查看新手引导",
                                    "重温 5 幕功能导览并重新启用首播手势提示",
                                    () -> {
                                        OnboardingScreen.resetForReplay(a);
                                        a.showOnboarding(true);
                                    });

                            TextView legal =
                                    a.text(
                                            "Marco Movie 仅为本地媒体播放与订阅解析工具，内置不包含任何影视内容资源。请仅导入您拥有合法授权的订阅配置与个人网盘内容。",
                                            12f,
                                            0x8cebebf5);
                            legal.setLineSpacing(a.dp(4), 1f);
                            legal.setPadding(a.dp(6), a.dp(10), a.dp(6), a.dp(4));
                            body.addView(legal, new LinearLayout.LayoutParams(-1, -2));
                        });
        top.add(aboutPane);

        return top;
    }

    /**
     * 1:1 {@code SettingsCapsule} from {@code ios_settings.dart}:
     * 36dp stadium radius, 18dp H / 14dp V padding, 38x38dp 18%-alpha circular badge + 21dp glyph,
     * 17sp w700 title + 12sp subtitle, right '›'.
     */
    private static View buildSettingsCapsule(MainActivity a, PaneSpec pane, Runnable onTap) {
        return buildCapsuleRow(a, pane.iconKind, pane.color, pane.title, pane.subtitle, onTap);
    }

    private static void addActionCapsule(
            MainActivity a,
            LinearLayout parent,
            int iconKind,
            int color,
            String title,
            String subtitle,
            Runnable onTap) {
        View v = buildCapsuleRow(a, iconKind, color, title, subtitle, onTap);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.bottomMargin = a.dp(10);
        parent.addView(v, lp);
    }

    private static View buildCapsuleRow(
            MainActivity a,
            int iconKind,
            int color,
            String title,
            String subtitle,
            Runnable onTap) {
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(a.dp(18), a.dp(14), a.dp(18), a.dp(14));

        int intensity = a.prefs.getInt(Prefs.MOBILE_GLASS_INTENSITY, 65);
        int fillAlpha = Math.round(0x14 + (intensity / 100f) * 0x16);
        GradientDrawable gd = new GradientDrawable();
        gd.setShape(GradientDrawable.RECTANGLE);
        gd.setCornerRadius(a.dp(36));
        gd.setColor((fillAlpha << 24) | 0x00ffffff);
        gd.setStroke(Math.max(1, a.dp(1)), 0x24ffffff);
        row.setBackground(gd);

        // 38x38dp circular icon container with 18% alpha tint
        FrameLayout badge = new FrameLayout(a);
        GradientDrawable circle = new GradientDrawable();
        circle.setShape(GradientDrawable.OVAL);
        circle.setColor((color & 0x00ffffff) | 0x2e000000);
        badge.setBackground(circle);
        badge.addView(
                new CapsuleIconView(a, iconKind, color),
                new FrameLayout.LayoutParams(a.dp(21), a.dp(21), Gravity.CENTER));
        LinearLayout.LayoutParams badgeLp = new LinearLayout.LayoutParams(a.dp(38), a.dp(38));
        badgeLp.rightMargin = a.dp(14);
        row.addView(badge, badgeLp);

        LinearLayout col = a.vertical();
        TextView t = a.text(title, 16.5f, 0xfff5f5f7);
        t.setTypeface(null, Typeface.BOLD);
        t.setSingleLine(true);
        t.setEllipsize(TextUtils.TruncateAt.END);
        col.addView(t);

        if (subtitle != null && !subtitle.isEmpty()) {
            TextView s = a.text(subtitle, 12f, 0xffd1d1da);
            s.setMaxLines(2);
            s.setEllipsize(TextUtils.TruncateAt.END);
            s.setPadding(0, a.dp(2), 0, 0);
            col.addView(s);
        }
        row.addView(col, new LinearLayout.LayoutParams(0, -2, 1f));

        TextView chev = a.text("›", 17f, 0x52ebebf5);
        chev.setTypeface(null, Typeface.BOLD);
        chev.setPadding(a.dp(8), 0, 0, a.dp(1));
        row.addView(chev);

        bindPressFeedback(row);
        row.setOnClickListener(v -> onTap.run());
        return row;
    }

    /**
     * 1:1 {@code SettingsChoices} from {@code ios_settings.dart}:
     * 13sp w600 #FFD1D1DA label + 8dp gap + wrapping {@code AppleCapsuleButton} pills (selected in
     * #FF0A84FF with '✓ ' prefix).
     */
    private static void addChoices(
            MainActivity a,
            LinearLayout parent,
            String label,
            String[] options,
            int selectedIndex,
            final ChoiceAction onSelect) {
        LinearLayout group = a.vertical();
        TextView heading = a.text(label, 13f, 0xffd1d1da);
        heading.setTypeface(null, Typeface.BOLD);
        heading.setPadding(a.dp(4), 0, a.dp(4), a.dp(8));
        group.addView(heading, new LinearLayout.LayoutParams(-1, -2));

        FlowWrapLayout wrap = new FlowWrapLayout(a, a.dp(8), a.dp(8));
        for (int i = 0; i < options.length; i++) {
            final int idx = i;
            boolean active = (i == selectedIndex);
            String pillLabel = active ? "✓ " + options[i] : options[i];
            TextView pill = a.text(pillLabel, 13f, active ? Color.WHITE : 0xe6f5f5f7);
            pill.setTypeface(null, active ? Typeface.BOLD : Typeface.NORMAL);
            pill.setSingleLine(true);
            pill.setGravity(Gravity.CENTER);
            pill.setPadding(a.dp(14), a.dp(8), a.dp(14), a.dp(8));

            GradientDrawable bg = new GradientDrawable();
            bg.setShape(GradientDrawable.RECTANGLE);
            bg.setCornerRadius(a.dp(999));
            if (active) {
                bg.setColor(COLOR_BLUE);
            } else {
                bg.setColor(0x1cffffff);
                bg.setStroke(Math.max(1, a.dp(1)), 0x26ffffff);
            }
            pill.setBackground(bg);
            bindPressFeedback(pill);
            pill.setOnClickListener(v -> onSelect.onSelect(idx));
            wrap.addView(pill);
        }
        group.addView(wrap, new LinearLayout.LayoutParams(-1, -2));

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.bottomMargin = a.dp(16);
        parent.addView(group, lp);
    }

    private static void addGlassSliderCard(
            final MainActivity a, LinearLayout parent, int currentVal, final PageController ctl) {
        LinearLayout box = a.vertical();
        box.setPadding(a.dp(16), a.dp(14), a.dp(16), a.dp(14));
        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.RECTANGLE);
        bg.setCornerRadius(a.dp(24));
        bg.setColor(0x1affffff);
        bg.setStroke(Math.max(1, a.dp(1)), 0x24ffffff);
        box.setBackground(bg);

        LinearLayout topRow = a.row();
        TextView label = a.text("玻璃磨砂强度", 14f, 0xfff5f5f7);
        label.setTypeface(null, Typeface.BOLD);
        topRow.addView(label, new LinearLayout.LayoutParams(0, -2, 1f));

        final TextView valTv = a.text(currentVal + "%", 13.5f, COLOR_TEAL);
        valTv.setTypeface(null, Typeface.BOLD);
        topRow.addView(valTv);
        box.addView(topRow, new LinearLayout.LayoutParams(-1, -2));

        a.gap(box, 8);
        SeekBar bar = new SeekBar(a);
        bar.setMax(100);
        bar.setProgress(Math.max(0, Math.min(100, currentVal)));
        if (Build.VERSION.SDK_INT >= 21) {
            bar.setProgressTintList(android.content.res.ColorStateList.valueOf(COLOR_BLUE));
            bar.setThumbTintList(android.content.res.ColorStateList.valueOf(Color.WHITE));
            bar.setProgressBackgroundTintList(
                    android.content.res.ColorStateList.valueOf(0x33ffffff));
        }
        bar.setOnSeekBarChangeListener(
                new SeekBar.OnSeekBarChangeListener() {
                    @Override
                    public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
                        valTv.setText(progress + "%");
                        if (fromUser) {
                            a.prefs
                                    .edit()
                                    .putInt(Prefs.MOBILE_GLASS_INTENSITY, progress)
                                    .putBoolean(Prefs.REDUCED_TRANSPARENCY, progress >= 96)
                                    .apply();
                            if (ctl.shell != null) ctl.shell.applyAppearancePreferences();
                        }
                    }

                    @Override
                    public void onStartTrackingTouch(SeekBar seekBar) {}

                    @Override
                    public void onStopTrackingTouch(SeekBar seekBar) {
                        GlassworkSurface.invalidateBackdrop(a.root);
                        ctl.rerenderInPlace();
                    }
                });
        box.addView(bar, new LinearLayout.LayoutParams(-1, -2));

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.bottomMargin = a.dp(16);
        parent.addView(box, lp);
    }

    private static int matchPresetOrCustom(int[] presets, int val) {
        for (int i = 0; i < presets.length; i++) {
            if (presets[i] == val) return i;
        }
        return presets.length;
    }

    private static int getStatusBarHeight(MainActivity a) {
        int resId = a.getResources().getIdentifier("status_bar_height", "dimen", "android");
        return resId > 0 ? a.getResources().getDimensionPixelSize(resId) : a.dp(24);
    }

    private static long computeDirBytes(File dir) {
        if (dir == null || !dir.exists()) return 0;
        long sum = 0;
        File[] children = dir.listFiles();
        if (children != null) {
            for (File f : children) {
                sum += f.isDirectory() ? computeDirBytes(f) : f.length();
            }
        }
        return sum;
    }

    private static void clearImageCacheFiles(File dir) {
        if (dir == null || !dir.exists()) return;
        File[] children = dir.listFiles();
        if (children == null) return;
        for (File f : children) {
            String n = f.getName();
            if (f.isDirectory()) {
                if ("home_snap_v1".equals(n) || n.contains("img") || n.contains("poster")) {
                    File[] sub = f.listFiles();
                    if (sub != null) for (File sf : sub) sf.delete();
                }
            } else if (n.endsWith(".img")
                    || n.startsWith("mob_hd_poster_")
                    || n.startsWith("tv_wide_")) {
                f.delete();
            }
        }
    }

    private static void bindPressFeedback(View view) {
        view.setOnTouchListener(
                (v, ev) -> {
                    int act = ev.getActionMasked();
                    if (act == MotionEvent.ACTION_DOWN) {
                        v.animate().scaleX(0.97f).scaleY(0.97f).setDuration(90).start();
                    } else if (act == MotionEvent.ACTION_UP || act == MotionEvent.ACTION_CANCEL) {
                        v.animate().scaleX(1f).scaleY(1f).setDuration(130).start();
                    }
                    return false;
                });
    }

    /** Multi-line wrapping layout matching Flutter's {@code Wrap(spacing, runSpacing)}. */
    static final class FlowWrapLayout extends ViewGroup {
        private final int hSpacing;
        private final int vSpacing;

        FlowWrapLayout(MainActivity a, int hSpacing, int vSpacing) {
            super(a);
            this.hSpacing = hSpacing;
            this.vSpacing = vSpacing;
        }

        @Override
        protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
            int maxWidth = MeasureSpec.getSize(widthMeasureSpec);
            int mode = MeasureSpec.getMode(widthMeasureSpec);
            if (mode == MeasureSpec.UNSPECIFIED || maxWidth <= 0) {
                maxWidth = getResources().getDisplayMetrics().widthPixels;
            }
            int availW = maxWidth - getPaddingLeft() - getPaddingRight();

            int lineW = 0;
            int lineH = 0;
            int totalH = getPaddingTop() + getPaddingBottom();
            int maxUsedW = 0;

            int count = getChildCount();
            for (int i = 0; i < count; i++) {
                View child = getChildAt(i);
                if (child.getVisibility() == GONE) continue;
                child.measure(
                        MeasureSpec.makeMeasureSpec(availW, MeasureSpec.AT_MOST),
                        MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED));
                int cw = child.getMeasuredWidth();
                int ch = child.getMeasuredHeight();
                if (lineW > 0 && lineW + hSpacing + cw > availW) {
                    maxUsedW = Math.max(maxUsedW, lineW);
                    totalH += lineH + vSpacing;
                    lineW = cw;
                    lineH = ch;
                } else {
                    lineW = lineW == 0 ? cw : lineW + hSpacing + cw;
                    lineH = Math.max(lineH, ch);
                }
            }
            maxUsedW = Math.max(maxUsedW, lineW);
            totalH += lineH;

            int finalW =
                    mode == MeasureSpec.EXACTLY
                            ? maxWidth
                            : Math.min(maxWidth, maxUsedW + getPaddingLeft() + getPaddingRight());
            setMeasuredDimension(finalW, resolveSize(totalH, heightMeasureSpec));
        }

        @Override
        protected void onLayout(boolean changed, int l, int t, int r, int b) {
            int availW = (r - l) - getPaddingRight();
            int x = getPaddingLeft();
            int y = getPaddingTop();
            int lineH = 0;

            int count = getChildCount();
            for (int i = 0; i < count; i++) {
                View child = getChildAt(i);
                if (child.getVisibility() == GONE) continue;
                int cw = child.getMeasuredWidth();
                int ch = child.getMeasuredHeight();
                if (x > getPaddingLeft() && x + cw > availW) {
                    x = getPaddingLeft();
                    y += lineH + vSpacing;
                    lineH = 0;
                }
                child.layout(x, y, x + cw, y + ch);
                x += cw + hSpacing;
                lineH = Math.max(lineH, ch);
            }
        }
    }

    /** Crisp anti-aliased Cupertino-inspired vector icons inside each 38x38dp capsule badge. */
    private static final class CapsuleIconView extends View {
        private final int kind;
        private final Paint stroke = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Path path = new Path();
        private final RectF rect = new RectF();

        CapsuleIconView(MainActivity a, int kind, int color) {
            super(a);
            this.kind = kind;
            stroke.setColor(color);
            stroke.setStyle(Paint.Style.STROKE);
            stroke.setStrokeWidth(Math.max(2f, a.dp(1.8f)));
            stroke.setStrokeCap(Paint.Cap.ROUND);
            stroke.setStrokeJoin(Paint.Join.ROUND);

            fill.setColor(color);
            fill.setStyle(Paint.Style.FILL);
        }

        @Override
        protected void onDraw(Canvas c) {
            float w = getWidth();
            float h = getHeight();
            if (w <= 0 || h <= 0) return;
            path.reset();
            switch (kind) {
                case ICON_SPARKLES:
                    {
                        // 4-point Cupertino sparkle star + secondary star
                        drawStar(c, w * 0.44f, h * 0.52f, w * 0.34f);
                        drawStar(c, w * 0.78f, h * 0.24f, w * 0.16f);
                        break;
                    }
                case ICON_GRID:
                case ICON_POSTER:
                    {
                        float r = w * 0.08f;
                        rect.set(w * 0.14f, h * 0.14f, w * 0.45f, h * 0.45f);
                        c.drawRoundRect(rect, r, r, stroke);
                        rect.set(w * 0.55f, h * 0.14f, w * 0.86f, h * 0.45f);
                        c.drawRoundRect(rect, r, r, stroke);
                        rect.set(w * 0.14f, h * 0.55f, w * 0.45f, h * 0.86f);
                        c.drawRoundRect(rect, r, r, stroke);
                        rect.set(w * 0.55f, h * 0.55f, w * 0.86f, h * 0.86f);
                        c.drawRoundRect(rect, r, r, stroke);
                        break;
                    }
                case ICON_PLAY_CIRCLE:
                    {
                        c.drawCircle(w * 0.5f, h * 0.5f, w * 0.38f, stroke);
                        path.moveTo(w * 0.42f, h * 0.35f);
                        path.lineTo(w * 0.66f, h * 0.50f);
                        path.lineTo(w * 0.42f, h * 0.65f);
                        path.close();
                        c.drawPath(path, fill);
                        break;
                    }
                case ICON_LAYERS:
                    {
                        path.moveTo(w * 0.50f, h * 0.16f);
                        path.lineTo(w * 0.86f, h * 0.34f);
                        path.lineTo(w * 0.50f, h * 0.52f);
                        path.lineTo(w * 0.14f, h * 0.34f);
                        path.close();
                        c.drawPath(path, stroke);
                        c.drawLine(w * 0.16f, h * 0.54f, w * 0.50f, h * 0.70f, stroke);
                        c.drawLine(w * 0.84f, h * 0.54f, w * 0.50f, h * 0.70f, stroke);
                        c.drawLine(w * 0.16f, h * 0.70f, w * 0.50f, h * 0.86f, stroke);
                        c.drawLine(w * 0.84f, h * 0.70f, w * 0.50f, h * 0.86f, stroke);
                        break;
                    }
                case ICON_TRAY:
                case ICON_BACKUP:
                    {
                        rect.set(w * 0.14f, h * 0.42f, w * 0.86f, h * 0.84f);
                        c.drawRoundRect(rect, w * 0.12f, w * 0.12f, stroke);
                        c.drawLine(w * 0.50f, h * 0.14f, w * 0.50f, h * 0.58f, stroke);
                        c.drawLine(w * 0.35f, h * 0.44f, w * 0.50f, h * 0.59f, stroke);
                        c.drawLine(w * 0.65f, h * 0.44f, w * 0.50f, h * 0.59f, stroke);
                        break;
                    }
                case ICON_INFO:
                    {
                        c.drawCircle(w * 0.5f, h * 0.5f, w * 0.38f, stroke);
                        c.drawCircle(w * 0.5f, h * 0.33f, w * 0.05f, fill);
                        c.drawLine(w * 0.5f, h * 0.46f, w * 0.5f, h * 0.70f, stroke);
                        break;
                    }
                case ICON_WALLPAPER:
                case ICON_HOME_MODULE:
                    {
                        rect.set(w * 0.14f, h * 0.18f, w * 0.86f, h * 0.82f);
                        c.drawRoundRect(rect, w * 0.14f, w * 0.14f, stroke);
                        c.drawCircle(w * 0.35f, h * 0.38f, w * 0.07f, fill);
                        path.moveTo(w * 0.20f, h * 0.76f);
                        path.lineTo(w * 0.46f, h * 0.52f);
                        path.lineTo(w * 0.62f, h * 0.66f);
                        path.lineTo(w * 0.78f, h * 0.50f);
                        c.drawPath(path, stroke);
                        break;
                    }
                case ICON_DROPLET:
                    {
                        path.moveTo(w * 0.50f, h * 0.14f);
                        path.cubicTo(
                                w * 0.82f, h * 0.48f, w * 0.80f, h * 0.84f, w * 0.50f, h * 0.86f);
                        path.cubicTo(
                                w * 0.20f, h * 0.84f, w * 0.18f, h * 0.48f, w * 0.50f, h * 0.14f);
                        c.drawPath(path, stroke);
                        break;
                    }
                case ICON_DISPLAY:
                    {
                        rect.set(w * 0.12f, h * 0.18f, w * 0.88f, h * 0.68f);
                        c.drawRoundRect(rect, w * 0.10f, w * 0.10f, stroke);
                        c.drawLine(w * 0.34f, h * 0.84f, w * 0.66f, h * 0.84f, stroke);
                        c.drawLine(w * 0.50f, h * 0.68f, w * 0.50f, h * 0.84f, stroke);
                        break;
                    }
                case ICON_SPEED:
                    {
                        rect.set(w * 0.14f, h * 0.20f, w * 0.86f, h * 0.88f);
                        c.drawArc(rect, 195f, 150f, false, stroke);
                        c.drawLine(w * 0.50f, h * 0.58f, w * 0.70f, h * 0.36f, stroke);
                        c.drawCircle(w * 0.50f, h * 0.58f, w * 0.06f, fill);
                        break;
                    }
                case ICON_SKIP:
                    {
                        path.moveTo(w * 0.20f, h * 0.28f);
                        path.lineTo(w * 0.58f, h * 0.50f);
                        path.lineTo(w * 0.20f, h * 0.72f);
                        path.close();
                        c.drawPath(path, stroke);
                        c.drawLine(w * 0.74f, h * 0.26f, w * 0.74f, h * 0.74f, stroke);
                        break;
                    }
                case ICON_CLOUD:
                    {
                        rect.set(w * 0.14f, h * 0.38f, w * 0.86f, h * 0.78f);
                        c.drawRoundRect(rect, w * 0.20f, w * 0.20f, stroke);
                        rect.set(w * 0.28f, h * 0.20f, w * 0.68f, h * 0.56f);
                        c.drawArc(rect, 195f, 160f, false, stroke);
                        break;
                    }
                default:
                    {
                        c.drawCircle(w * 0.5f, h * 0.5f, w * 0.34f, stroke);
                        break;
                    }
            }
        }

        private void drawStar(Canvas c, float cx, float cy, float r) {
            path.reset();
            float inner = r * 0.30f;
            path.moveTo(cx, cy - r);
            path.quadTo(cx + inner, cy - inner, cx + r, cy);
            path.quadTo(cx + inner, cy + inner, cx, cy + r);
            path.quadTo(cx - inner, cy + inner, cx - r, cy);
            path.quadTo(cx - inner, cy - inner, cx, cy - r);
            path.close();
            c.drawPath(path, fill);
        }
    }
}
