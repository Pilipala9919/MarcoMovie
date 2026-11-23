package com.pilipala.marcomovie;

import android.animation.ValueAnimator;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.Editable;
import android.text.InputType;
import android.text.TextUtils;
import android.text.TextWatcher;
import android.view.Gravity;
import android.view.View;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.io.File;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;

/**
 * Pure Android Mobile & Tablet Settings Center ({@code MobileSettingsScreen}):
 * - Instant top search bar across all 50+ mobile settings with sub-page jump & animated row
 *   highlight flash ({@code SettingsFlash})
 * - 7 clean mobile-native groups with ZERO fallthrough to TV {@code SettingsScreen} and ZERO TV-only
 *   layout options.
 */
final class MobileSettingsScreen {
    private MobileSettingsScreen() {}

    static void render(final MobileRootShell shell, final FrameLayout container) {
        final MainActivity a = shell.a;
        final ScrollView sv = new ScrollView(a);
        sv.setVerticalScrollBarEnabled(false);
        sv.setFillViewport(true);
        shell.bindScrollBehavior(sv);

        final LinearLayout body = a.vertical();
        body.setPadding(a.dp(16), a.statusBarHeight() + a.dp(10), a.dp(16), a.dp(112));
        sv.addView(body, new ScrollView.LayoutParams(-1, -2));
        container.addView(sv, new FrameLayout.LayoutParams(-1, -1));

        populate(shell, body, sv);
    }

    private static void reloadPage(MobileRootShell shell) {
        shell.switchTab(MobileRootShell.TAB_SETTINGS);
    }

    private static void populate(
            final MobileRootShell shell, final LinearLayout body, final ScrollView sv) {
        final MainActivity a = shell.a;
        body.removeAllViews();
        int sub = MobileRootShell.settingsSubPage;

        if (sub == 0) {
            renderRootOverview(shell, body);
            return;
        }

        // Sub-page top bar with back button
        String[] subTitles = {
            "", "片源与直播", "外观与导航", "播放与手势", "字幕与弹幕", "刮削、账号与 AI 服务", "云同步、网盘与隐私", "存储、更新与关于"
        };
        LinearLayout navRow = a.row();
        navRow.setGravity(Gravity.CENTER_VERTICAL);
        navRow.setPadding(0, 0, 0, a.dp(14));

        TextView backBtn = a.text("‹", 22, Color.WHITE);
        backBtn.setGravity(Gravity.CENTER);
        backBtn.setBackground(
                UiWidgets.glassBg(0xc8222b28, 0xc8161d1b, a.dp(999), a.dp(0.8f), 0x38ffffff));
        UiWidgets.bindTouchFeedback(backBtn);
        backBtn.setOnClickListener(
                v -> {
                    MobileRootShell.settingsSubPage = 0;
                    MobileRootShell.settingsHighlightKey = "";
                    reloadPage(shell);
                });
        LinearLayout.LayoutParams bLp = new LinearLayout.LayoutParams(a.dp(38), a.dp(38));
        bLp.rightMargin = a.dp(12);
        navRow.addView(backBtn, bLp);

        TextView title = a.text(subTitles[Math.min(sub, subTitles.length - 1)], 21, Color.WHITE);
        title.setTypeface(null, Typeface.BOLD);
        navRow.addView(title, new LinearLayout.LayoutParams(0, -2, 1f));
        body.addView(navRow, new LinearLayout.LayoutParams(-1, -2));

        switch (sub) {
            case 1:
                renderSubSourcesAndLive(shell, body);
                break;
            case 2:
                renderSubAppearanceAndNav(shell, body);
                break;
            case 3:
                renderSubPlaybackAndGesture(shell, body);
                break;
            case 4:
                renderSubSubtitleAndDanmaku(shell, body);
                break;
            case 5:
                renderSubScrapingAccountsAndAi(shell, body);
                break;
            case 6:
                renderSubSyncAndTvConnect(shell, body);
                break;
            case 7:
            default:
                renderSubStorageUpdateAndAbout(shell, body);
                break;
        }

        // Scroll to & flash target setting card when navigated from Instant Settings Search!
        if (MobileRootShell.settingsHighlightKey != null
                && !MobileRootShell.settingsHighlightKey.isEmpty()) {
            final String targetKey = MobileRootShell.settingsHighlightKey;
            MobileRootShell.settingsHighlightKey = "";
            body.post(
                    () -> {
                        View target = body.findViewWithTag(targetKey);
                        if (target != null) {
                            int y = Math.max(0, target.getTop() - a.dp(60));
                            sv.smoothScrollTo(0, y);
                            flashSettingRow(a, target);
                        }
                    });
        }
    }

    private static void renderRootOverview(final MobileRootShell shell, final LinearLayout body) {
        final MainActivity a = shell.a;
        TextView heading = a.text("设置中心", 24, Color.WHITE);
        heading.setTypeface(null, Typeface.BOLD);
        body.addView(heading);
        a.gap(body, 12);

        // Instant Settings Search Bar
        LinearLayout searchWrap = a.row();
        searchWrap.setGravity(Gravity.CENTER_VERTICAL);
        searchWrap.setPadding(a.dp(14), a.dp(8), a.dp(14), a.dp(8));
        searchWrap.setBackground(
                UiWidgets.glassBg(0xd41d2623, 0xd4131917, a.dp(999), a.dp(0.9f), 0x36ffffff));
        final EditText searchInput = new EditText(a);
        searchInput.setHint("🔍 搜索设置项（如：TMDB、AI、手势、字幕、弹幕、小窗…）");
        searchInput.setHintTextColor(0xff7c858e);
        searchInput.setTextColor(Color.WHITE);
        searchInput.setTextSize(13.5f);
        searchInput.setSingleLine(true);
        searchInput.setBackgroundColor(Color.TRANSPARENT);
        searchInput.setPadding(0, a.dp(2), 0, a.dp(2));
        searchWrap.addView(searchInput, new LinearLayout.LayoutParams(0, -2, 1f));
        body.addView(searchWrap, new LinearLayout.LayoutParams(-1, -2));
        a.gap(body, 14);

        final LinearLayout searchHitsBox = a.vertical();
        searchHitsBox.setVisibility(View.GONE);
        body.addView(searchHitsBox, new LinearLayout.LayoutParams(-1, -2));

        final LinearLayout groupsBox = a.vertical();
        body.addView(groupsBox, new LinearLayout.LayoutParams(-1, -2));

        searchInput.addTextChangedListener(
                new TextWatcher() {
                    @Override
                    public void beforeTextChanged(
                            CharSequence s, int start, int count, int after) {}

                    @Override
                    public void onTextChanged(CharSequence s, int start, int before, int count) {}

                    @Override
                    public void afterTextChanged(Editable s) {
                        String q = s.toString().trim();
                        if (q.isEmpty()) {
                            searchHitsBox.setVisibility(View.GONE);
                            groupsBox.setVisibility(View.VISIBLE);
                            return;
                        }
                        List<MobileSettingsIndex.Entry> hits = MobileSettingsIndex.search(q);
                        groupsBox.setVisibility(View.GONE);
                        searchHitsBox.setVisibility(View.VISIBLE);
                        searchHitsBox.removeAllViews();
                        if (hits.isEmpty()) {
                            searchHitsBox.addView(
                                    a.text("未找到包含“" + q + "”的手机设置项", 13f, MainActivity.MUTED));
                            return;
                        }
                        for (final MobileSettingsIndex.Entry hit : hits) {
                            addCard(
                                    a,
                                    searchHitsBox,
                                    hit.key,
                                    UiWidgets.SettingIconView.kindForSetting(hit.key, hit.title),
                                    hit.title,
                                    "所属分组：" + hit.groupName + " · 点击直达并高亮定位",
                                    () -> {
                                        MobileRootShell.settingsSubPage = hit.subPage;
                                        MobileRootShell.settingsHighlightKey = hit.key;
                                        reloadPage(shell);
                                    });
                        }
                    }
                });

        String siteSum =
                a.config == null
                        ? "未导入配置 · 点击快速粘贴或选择文件"
                        : ("已装载 " + a.config.sites.size() + " 个片源 · 直播与爬虫引擎管理");
        addCard(
                a,
                groupsBox,
                "ms-grp-1",
                UiWidgets.SettingIconView.ICON_SOURCES,
                "片源与直播",
                siteSum,
                () -> {
                    MobileRootShell.settingsSubPage = 1;
                    reloadPage(shell);
                });

        addCard(
                a,
                groupsBox,
                "ms-grp-2",
                UiWidgets.SettingIconView.ICON_APPEARANCE,
                "外观与导航",
                "液态玻璃 4+1 底栏、上滑折叠、封面柔光、主题强调色与整体缩放",
                () -> {
                    MobileRootShell.settingsSubPage = 2;
                    reloadPage(shell);
                });

        addCard(
                a,
                groupsBox,
                "ms-grp-3",
                UiWidgets.SettingIconView.ICON_PLAYBACK,
                "播放与手势",
                "详情页竖屏小窗起播、集名净化、MPV/Media3、双指换集、按钮编排",
                () -> {
                    MobileRootShell.settingsSubPage = 3;
                    reloadPage(shell);
                });

        addCard(
                a,
                groupsBox,
                "ms-grp-4",
                UiWidgets.SettingIconView.ICON_SUBTITLE,
                "字幕与弹幕",
                "全屏触控字幕调校、在线字幕站、AI 双语翻译、弹幕源测速排序",
                () -> {
                    MobileRootShell.settingsSubPage = 4;
                    reloadPage(shell);
                });

        String onlineStatus =
                (TmdbService.isConfigured(a) ? "TMDB 已启用" : "TMDB 未配置")
                        + " · "
                        + (AiAssistantService.isConfigured(a)
                                ? AiAssistantService.providerLabel(
                                        a.mobilePrefs().getString(Prefs.AI_PROVIDER, "deepseek"))
                                : "AI 助手未开启");
        addCard(
                a,
                groupsBox,
                "ms-grp-5",
                UiWidgets.SettingIconView.ICON_AI_SPARKLE,
                "刮削、账号与 AI 服务",
                onlineStatus + " · Bangumi / Trakt / MDBList",
                () -> {
                    MobileRootShell.settingsSubPage = 5;
                    reloadPage(shell);
                });

        addCard(
                a,
                groupsBox,
                "ms-grp-6",
                UiWidgets.SettingIconView.ICON_NETDISK,
                "云同步、网盘与隐私",
                "WebDAV 自动增量同步、网盘扫码授权、隐私空间与局域网推源",
                () -> {
                    MobileRootShell.settingsSubPage = 6;
                    reloadPage(shell);
                });

        addCard(
                a,
                groupsBox,
                "ms-grp-7",
                UiWidgets.SettingIconView.ICON_SYSTEM,
                "存储、更新与关于",
                "手机端独立备份与恢复、分项缓存清理、诊断日志 · v" + UpdateManager.installedVersion(a),
                () -> {
                    MobileRootShell.settingsSubPage = 7;
                    reloadPage(shell);
                });
    }

    // =========================================================================
    // GROUP 1: 片源与直播
    // =========================================================================
    private static void renderSubSourcesAndLive(MobileRootShell shell, LinearLayout body) {
        final MainActivity a = shell.a;
        sectionHeader(a, body, "配置源与多仓");
        addCard(
                a,
                body,
                "ms-clip-import",
                UiWidgets.SettingIconView.ICON_CLIPBOARD,
                "一键读取剪贴板导入配置",
                "自动识别剪贴板中的 JSON / JS / PY / M3U / ZIP 配置链接或文本",
                () -> UiWidgets.pasteConfigFromClipboard(a));
        addCard(
                a,
                body,
                "ms-url-import",
                UiWidgets.SettingIconView.ICON_LINK_CODE,
                "输入配置网址或选择本地包",
                a.configOrigin.isEmpty() ? "支持单仓、多仓及本地 .zip 离线包" : ("当前：" + a.configOrigin),
                () -> UiWidgets.showMobileImportDialog(a));
        addCard(
                a,
                body,
                "ms-switch-site",
                UiWidgets.SettingIconView.ICON_SWITCH_SOURCE,
                "切换默认首页片源",
                shell.activeSite == null ? "当前未选择片源" : ("当前激活：" + shell.activeSite.name),
                shell::showQuickSourceAndModeSheet);
        addCoreToggle(
                a,
                body,
                "ms-sub-auto",
                "订阅源每日自动静默更新",
                Prefs.SUBSCRIPTION_AUTO_UPDATE,
                true,
                "已开启 · 每 24 小时后台校验刷新订阅源",
                "已关闭 · 仅手动更新订阅",
                null);
        addCard(
                a,
                body,
                "ms-sub-refresh-now",
                UiWidgets.SettingIconView.ICON_UPDATE_CLOUD,
                "立即刷新当前已导入订阅源",
                a.prefs.getString(Prefs.SUBSCRIPTION_LAST_AUTO_STATUS, "点击立即拉取远程订阅最新站点列表"),
                () -> {
                    a.toast("正在后台刷新订阅源…");
                    SourceController.runDailyAutoUpdateIfNeeded(a, true);
                });
        if (a.config != null && a.config.depots != null && a.config.depots.length() > 1) {
            addCard(
                    a,
                    body,
                    "ms-depots",
                    UiWidgets.SettingIconView.ICON_SWITCH_SOURCE,
                    "切换影视仓子仓库",
                    "共 " + a.config.depots.length() + " 个子仓库",
                    () -> SourcePicker.showWarehouses(a));
        }

        sectionHeader(a, body, "电视直播与节目单");
        addCard(
                a,
                body,
                "ms-live-import",
                UiWidgets.SettingIconView.ICON_LIVE_TV,
                "电视直播源管理 (M3U / TXT / JSON)",
                "支持叠加多份直播订阅与自定义频道列表",
                () -> SourceController.showLiveImportDialog(a));
        String epg = a.prefs.getString(Prefs.LIVE_EPG_URL, "");
        addCard(
                a,
                body,
                "ms-live-epg",
                UiWidgets.SettingIconView.ICON_SUBTITLE,
                "自定义 XMLTV 节目单 (EPG)",
                epg.isEmpty() ? "默认读取直播列表内 x-tvg-url" : ("当前：" + epg),
                () -> SourceController.showEpgDialog(a));
        String udpxy = a.prefs.getString(Prefs.LIVE_UDPXY_URL, "");
        addCard(
                a,
                body,
                "ms-live-udpxy",
                UiWidgets.SettingIconView.ICON_LIVE_TV,
                "组播转单播网关 (udpxy)",
                udpxy.isEmpty() ? "未配置路由器 udpxy / rtp2httpd 地址" : ("当前：" + udpxy),
                () -> SourceController.showUdpxyDialog(a));
        addCoreToggle(
                a,
                body,
                "ms-live-hq",
                "直播优先最高画质与 IPv6",
                Prefs.LIVE_HIGH_QUALITY,
                true,
                "开启 · 自动优选高码率与低首帧延迟线路",
                "关闭 · 按列表原始顺序播放",
                null);
        addCoreToggle(
                a,
                body,
                "ms-live-merge",
                "同名直播频道跨源聚合",
                Prefs.LIVE_MERGE_SOURCES,
                true,
                "开启 · 同名频道合并为多线路切换",
                "关闭 · 各直播源独立显示",
                null);

        sectionHeader(a, body, "聚合搜索与爬虫引擎");
        addMobileToggle(
                a,
                body,
                "ms-search-sidebar",
                "搜索页左侧纵向平台筛选栏",
                Prefs.SEARCH_PLATFORM_SIDEBAR,
                false,
                "左侧竖栏 · 适合多片源单手拇指快速切换",
                "顶部横排胶囊 · 最大化结果展示宽度",
                null);
        addCoreIntPicker(
                shell,
                body,
                "ms-search-threads",
                "聚合搜索并发源数",
                Prefs.SEARCH_THREADS,
                new String[] {"2 个片源 · 省电", "4 个片源 · 均衡", "6 个片源 · 极速"},
                new int[] {2, 4, 6},
                6);
        addCoreToggle(
                a,
                body,
                "ms-ext-csp",
                "启用第三方爬虫扩展 (JAR)",
                Prefs.EXPERIMENTAL_CSP,
                true,
                "已启用 · 请仅导入你信任的配置源",
                "已禁用",
                a::closeEngines);
        addCoreToggle(
                a,
                body,
                "ms-ext-py",
                "内置 CPython 3.11 爬虫引擎",
                Prefs.NATIVE_PYTHON_ENABLED,
                true,
                "已启用 · 支持原生 .py 爬虫脚本",
                "已禁用",
                a::closeEngines);
        addCoreToggle(
                a,
                body,
                "ms-ext-js",
                "异步 JS 源 WebView 兜底",
                Prefs.WEBVIEW_JS_FALLBACK,
                true,
                "已启用",
                "已禁用",
                a::closeEngines);
    }

    // =========================================================================
    // GROUP 2: 外观与导航
    // =========================================================================
    private static void renderSubAppearanceAndNav(MobileRootShell shell, LinearLayout body) {
        final MainActivity a = shell.a;
        sectionHeader(a, body, "界面缩放与主题配色");
        int curScale =
                Prefs.clampMobileUiScale(
                        a.mobilePrefs().getInt(Prefs.MOBILE_UI_SCALE_PERCENT, 100));
        addCard(
                a,
                body,
                "ms-ui-scale",
                UiWidgets.SettingIconView.ICON_UI_SCALE,
                "界面整体缩放",
                curScale + "% · 适配手机与平板屏幕密度",
                () -> {
                    String[] labels = {"紧凑 · 90%", "标准 · 100%", "舒展 · 110%", "大字 · 120%"};
                    int[] vals = {90, 100, 110, 120};
                    int sel = 1;
                    for (int i = 0; i < vals.length; i++) if (vals[i] == curScale) sel = i;
                    UiWidgets.showDrawerPicker(
                            a,
                            "手机界面整体缩放",
                            "选择后立即重载手机界面密度",
                            labels,
                            sel,
                            idx -> {
                                a.mobilePrefs()
                                        .edit()
                                        .putInt(Prefs.MOBILE_UI_SCALE_PERCENT, vals[idx])
                                        .commit();
                                a.recreate();
                            });
                });

        addMobileIntPicker(
                shell,
                body,
                "ms-accent",
                "主题强调色预设",
                Prefs.ACCENT_PRESET,
                new String[] {"翡翠青绿 (默认)", "天际蔚蓝", "绯红玫粉", "琥珀流金", "鸢尾霓紫", "青柠薄荷", "暖阳珊瑚", "石墨冷银"},
                new int[] {0, 1, 2, 3, 4, 5, 6, 7},
                0);

        sectionHeader(a, body, "导航壳层与首页布局");
        addMobileIntPicker(
                shell,
                body,
                "ms-nav-style",
                "底部导航栏形态",
                Prefs.NAV_STYLE,
                new String[] {"液态玻璃 4 + 1（右侧独立圆形搜索钮）", "紧凑一体式五栏胶囊"},
                new int[] {0, 1},
                0);
        addMobileIntPicker(
                shell,
                body,
                "ms-nav-scroll",
                "底栏滚动行为",
                Prefs.NAV_SCROLL_BEHAVIOR,
                new String[] {"始终常驻显示", "上滑折叠为紧凑浮钮（保留右侧搜索钮）", "上滑完全自动隐藏"},
                new int[] {0, 1, 2},
                1);
        addMobileIntPicker(
                shell,
                body,
                "ms-home-mode",
                "首页默认发现模式",
                Prefs.HOME_MODE,
                new String[] {"片源自带分类界面", "TMDB 全球趋势推荐首页"},
                new int[] {0, 1},
                0);
        addMobileToggle(
                a,
                body,
                "ms-home-banner",
                "首页精选大图横幅",
                Prefs.HOME_CAROUSEL,
                true,
                "开启 · 顶部展示推荐焦点大图",
                "关闭 · 直接平铺三列海报网格",
                null);
        addMobileToggle(
                a,
                body,
                "ms-cover-ambient",
                "封面主色自适应柔光",
                Prefs.COVER_AMBIENT,
                true,
                "开启 · 页面背景随封面色调柔和晕染",
                "关闭 · 纯黑曜石暗色底",
                null);

        sectionHeader(a, body, "全局背景与视觉性能");
        boolean wpOn = a.prefs.getBoolean(Prefs.WALLPAPER_ENABLED, false);
        addCard(
                a,
                body,
                "ms-wallpaper",
                UiWidgets.SettingIconView.ICON_WALLPAPER,
                "自定义背景图片与压暗度",
                wpOn
                        ? ("已启用自定义背景 · 压暗 " + a.prefs.getInt(Prefs.WALLPAPER_DIM, 65) + "%")
                        : "当前使用动态氛围背景（点击可导入本地图片）",
                () -> {
                    String[] opts = {
                        "从手机相册选择背景图",
                        "遮挡压暗度 · 45%（通透）",
                        "遮挡压暗度 · 65%（推荐）",
                        "遮挡压暗度 · 82%（深邃）",
                        "恢复默认动态氛围背景"
                    };
                    UiWidgets.showDrawerPicker(
                            a,
                            "自定义背景图片",
                            "垫入背景图并通过遮挡度保障海报文字清晰可读",
                            opts,
                            wpOn ? 2 : 4,
                            idx -> {
                                if (idx == 0) {
                                    BackupManager.pickDocument(a, 44, "image/*", false);
                                } else if (idx >= 1 && idx <= 3) {
                                    int dim = idx == 1 ? 45 : (idx == 2 ? 65 : 82);
                                    a.prefs
                                            .edit()
                                            .putInt(Prefs.WALLPAPER_DIM, dim)
                                            .putBoolean(Prefs.WALLPAPER_ENABLED, true)
                                            .apply();
                                    MobileRootShell.show(a);
                                } else {
                                    a.prefs
                                            .edit()
                                            .putBoolean(Prefs.WALLPAPER_ENABLED, false)
                                            .apply();
                                    MobileRootShell.show(a);
                                }
                            });
                });
        addCoreToggle(
                a,
                body,
                "ms-glass-toggle",
                "关闭液态玻璃透明效果（性能优先）",
                Prefs.REDUCED_TRANSPARENCY,
                false,
                "已关闭透明 · 底栏与卡片使用高对比纯色",
                "已开启液态玻璃 · 半透明毛玻璃质感",
                () -> MobileRootShell.show(a));
        addCoreToggle(
                a,
                body,
                "ms-reduced-motion",
                "精简界面过渡动画",
                Prefs.REDUCED,
                false,
                "已精简 · 关闭缩放与回弹动效",
                "标准灵动动画",
                () -> a.reduced = a.prefs.getBoolean(Prefs.REDUCED, false));
    }

    // =========================================================================
    // GROUP 3: 播放与手势
    // =========================================================================
    private static void renderSubPlaybackAndGesture(MobileRootShell shell, LinearLayout body) {
        final MainActivity a = shell.a;
        sectionHeader(a, body, "详情页与选集衔接");
        addMobileIntPicker(
                shell,
                body,
                "ms-detail-tap",
                "详情页点选剧集行为",
                Prefs.DETAIL_TAP_MODE,
                new String[] {"竖屏顶部内嵌小窗直接起播（推荐）", "直接切换横屏全屏播放", "仅选中剧集，点击主播放按钮再起播"},
                new int[] {0, 1, 2},
                0);
        addMobileIntPicker(
                shell,
                body,
                "ms-ep-clean",
                "选集集名智能净化模式",
                Prefs.EPISODE_CLEAN_MODE,
                new String[] {"自动本地正则净化（零联网毫秒级）", "显示片源原始集名", "AI 大模型优先深度净化（需配置 AI Key）"},
                new int[] {0, 1, 2},
                0);

        sectionHeader(a, body, "播放内核与画质增强");
        addCoreIntPicker(
                shell,
                body,
                "ms-player-engine",
                "默认播放器内核",
                Prefs.PLAYER_ENGINE,
                new String[] {
                    "Media3 (ExoPlayer · 均衡稳定)", "Android 系统播放器", "MPV (高画质 / HDR / Anime4K)"
                },
                new int[] {0, 1, 2},
                0);
        addMobileToggle(
                a,
                body,
                "ms-auto-switch-kernel",
                "播放失败自动尝试切换备用内核",
                Prefs.AUTO_SWITCH_KERNEL,
                true,
                "已开启",
                "已关闭",
                null);
        addCoreIntPicker(
                shell,
                body,
                "ms-decoder-mode",
                "视频解码方式",
                Prefs.DECODER_MODE,
                new String[] {"自动选择", "硬件解码优先 (HW)", "软件解码优先 (SW)"},
                new int[] {0, 1, 2},
                0);
        addCoreToggle(
                a,
                body,
                "ms-hdr-tone",
                "MPV HDR 自动色调映射",
                Prefs.HDR_TONE_MAPPING,
                true,
                "已开启",
                "已关闭",
                null);
        addCoreToggle(
                a,
                body,
                "ms-anime4k",
                "MPV Anime4K 实时动漫超分",
                Prefs.ANIME4K_ENABLED,
                false,
                "已开启 · 高负载耗电略增",
                "已关闭",
                null);
        addMobileToggle(
                a,
                body,
                "ms-letterbox",
                "宽银幕黑边氛围柔光填充",
                Prefs.LETTERBOX_BLUR,
                false,
                "已开启 · 21:9 电影上下黑边晕染环境光",
                "已关闭 · 纯黑电影遮幅",
                null);

        sectionHeader(a, body, "触屏手势与防误触");
        addMobileToggle(
                a,
                body,
                "ms-swipe-swap",
                "互换左右半屏亮度与音量手势",
                Prefs.SWIPE_SWAP_LR,
                false,
                "已互换 · 左半屏调音量，右半屏调亮度",
                "默认 · 左半屏调亮度，右半屏调音量",
                null);
        addMobileToggle(
                a,
                body,
                "ms-src-bright",
                "按片源独立记忆播放屏幕亮度",
                Prefs.REMEMBER_SOURCE_BRIGHTNESS,
                true,
                "已开启 · 自动恢复上次观看该片源时的亮度",
                "已关闭 · 跟随当前窗口亮度",
                null);
        float curBoost = a.mobilePrefs().getFloat(Prefs.LONG_PRESS_SPEED, 2.0f);
        addCard(
                a,
                body,
                "ms-long-speed",
                UiWidgets.SettingIconView.ICON_SPEED_GAUGE,
                "长按画面加速倍速",
                String.format(Locale.US, "当前 %.1f× · 长按时向右微滑可动态升至 4.0×", curBoost),
                () -> {
                    String[] labels = {
                        "1.5× 轻快倍速", "2.0× 标准二倍速（推荐）", "2.5× 进阶倍速", "3.0× 三倍速刷剧", "4.0× 极速浏览"
                    };
                    float[] vals = {1.5f, 2.0f, 2.5f, 3.0f, 4.0f};
                    int sel = 1;
                    for (int i = 0; i < vals.length; i++) {
                        if (Math.abs(vals[i] - curBoost) < 0.1f) sel = i;
                    }
                    UiWidgets.showDrawerPicker(
                            a,
                            "长按画面加速档位",
                            "松手自动恢复原播放速度",
                            labels,
                            sel,
                            idx -> {
                                a.mobilePrefs()
                                        .edit()
                                        .putFloat(Prefs.LONG_PRESS_SPEED, vals[idx])
                                        .apply();
                                reloadPage(shell);
                            });
                });
        addMobileIntPicker(
                shell,
                body,
                "ms-vert-ep",
                "上下滑动切换上下集",
                Prefs.VERTICAL_SWIPE_EPISODE,
                new String[] {"关闭上下滑换集", "双指上下滑换集（防调亮度/音量误触 · 推荐）", "画面中区单指上下滑换集"},
                new int[] {0, 1, 2},
                1);

        sectionHeader(a, body, "播放器界面、跳过片头与后台");
        int hudMask = a.mobilePrefs().getInt(Prefs.PLAYER_CORNER_HUD, 7);
        addCard(
                a,
                body,
                "ms-corner-hud",
                UiWidgets.SettingIconView.ICON_ASPECT_RATIO,
                "播放页右上角常驻状态信息",
                describeHudMask(hudMask),
                () -> showCornerHudConfigSheet(shell));
        addMobileToggle(
                a,
                body,
                "ms-mini-bar",
                "面板隐藏后底部保留 2dp 迷你进度线",
                Prefs.MINI_PROGRESS_BAR,
                true,
                "已开启 · 不遮挡字幕即可感知剩余进度",
                "已关闭",
                null);
        addCard(
                a,
                body,
                "ms-btn-order",
                UiWidgets.SettingIconView.ICON_NAV_FONT,
                "播放页工具栏按钮顺序编排",
                "自定义选集、换源、倍速、在线字幕、AI双语、弹幕、小窗顺序",
                () -> showPlayerButtonOrderDialog(shell));
        addMobileToggle(
                a,
                body,
                "ms-skip-intro",
                "TheIntroDB 社区数据库自动跳过片头",
                Prefs.THEINTRODB_AUTO_SKIP,
                true,
                "已开启 · 匹配 TMDB 后自动识别剧集片头时间点",
                "已关闭 · 仅使用手动秒数设置",
                null);
        int sIntro = Prefs.clampSkipSeconds(a.prefs.getInt(Prefs.SKIP_INTRO, 0));
        int sOutro = Prefs.clampSkipSeconds(a.prefs.getInt(Prefs.SKIP_OUTRO, 0));
        addCard(
                a,
                body,
                "ms-manual-skip",
                UiWidgets.SettingIconView.ICON_SKIP_TIMELINE,
                "手动设置全局片头 / 片尾跳过秒数",
                "片头：" + sIntro + " 秒  ·  片尾：" + sOutro + " 秒",
                () ->
                        UiWidgets.showDrawerPicker(
                                a,
                                "手动跳过片头 / 片尾",
                                "精准拉取全局默认跳过秒数",
                                new String[] {"调节跳过片头秒数", "调节跳过片尾秒数", "清零手动片头片尾"},
                                0,
                                idx -> {
                                    if (idx == 0) {
                                        PlaybackControls.showSkipAdjuster(
                                                a, true, 0, 0, () -> reloadPage(shell));
                                    } else if (idx == 1) {
                                        PlaybackControls.showSkipAdjuster(
                                                a, false, 0, 0, () -> reloadPage(shell));
                                    } else {
                                        a.prefs
                                                .edit()
                                                .putInt(Prefs.SKIP_INTRO, 0)
                                                .putInt(Prefs.SKIP_OUTRO, 0)
                                                .apply();
                                        reloadPage(shell);
                                    }
                                }));
        addMobileToggle(
                a,
                body,
                "ms-pip-bg",
                "按 Home 键自动进入画中画小窗 (PiP)",
                Prefs.AUTO_PIP,
                true,
                "已开启 · 全屏播放退桌面时自动悬浮小窗",
                "已关闭",
                null);
        addMobileToggle(
                a,
                body,
                "ms-bg-audio",
                "退后台 / 锁屏继续播放音频",
                Prefs.BACKGROUND_PLAY,
                false,
                "已开启 · 适合听剧或相声综艺",
                "已关闭 · 退后台自动暂停",
                null);
        addCoreIntPicker(
                shell,
                body,
                "ms-loudness",
                "音量响度增益",
                Prefs.LOUDNESS_BOOST,
                new String[] {"关闭增益", "+3 dB", "+6 dB", "+10 dB", "+15 dB"},
                new int[] {0, 3, 6, 10, 15},
                0);
        addCoreToggle(
                a,
                body,
                "ms-hls-proxy",
                "HLS 伪装头清洗本地代理",
                Prefs.HLS_PROXY_ENABLED,
                true,
                "已开启",
                "已关闭",
                null);
        addCoreToggle(
                a,
                body,
                "ms-hls-ad",
                "HLS 切片流插播广告段过滤",
                Prefs.HLS_AD_STRIP,
                false,
                "已开启",
                "已关闭",
                null);
    }

    // =========================================================================
    // GROUP 4: 字幕与弹幕
    // =========================================================================
    private static void renderSubSubtitleAndDanmaku(MobileRootShell shell, LinearLayout body) {
        final MainActivity a = shell.a;
        sectionHeader(a, body, "字幕渲染与在线双语字幕");
        int subSize = Prefs.clampSubtitleSize(a.prefs.getInt(Prefs.SUBTITLE_SIZE, 45));
        int subBot = Prefs.clampSubtitleBottom(a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24));
        addCard(
                a,
                body,
                "ms-sub-adjust",
                UiWidgets.SettingIconView.ICON_SUBTITLE,
                "全屏触控字幕调校（双指缩放 · 拖拽定位）",
                "当前字号 " + subSize + " · 底距 " + subBot + "dp",
                () -> PlaybackControls.showSubtitleAdjuster(a, null, () -> reloadPage(shell)));
        addCoreIntPicker(
                shell,
                body,
                "ms-sub-style",
                "字幕配色与描边底衬样式",
                Prefs.SUBTITLE_STYLE,
                SubtitleOverlayView.STYLE_LABELS,
                new int[] {0, 1, 2, 3, 4, 5, 6, 7},
                0);
        boolean hasSubKeys =
                !a.secretsPrefs().getString(Prefs.SECRET_ASSRT_TOKEN, "").trim().isEmpty()
                        || !a.secretsPrefs()
                                .getString(Prefs.SECRET_OPENSUBTITLES_KEY, "")
                                .trim()
                                .isEmpty();
        addCard(
                a,
                body,
                "ms-online-sub",
                UiWidgets.SettingIconView.ICON_LINK_CODE,
                "在线字幕站凭据配置 (Assrt / OpenSubtitles)",
                hasSubKeys ? "已配置本机字幕站凭据（不随公开备份导出）" : "填入个人免费 Token 以启用播放页在线搜字幕",
                () -> showOnlineSubtitleCredentialDialog(shell));
        addMobileToggle(
                a,
                body,
                "ms-sub-bilingual",
                "AI 实时翻译字幕保留双语对照",
                Prefs.SUBTITLE_BILINGUAL,
                true,
                "已开启 · 中文译文下方保留外语原句",
                "仅显示中文译文",
                null);

        sectionHeader(a, body, "弹幕样式与多弹幕源测速");
        addCard(
                a,
                body,
                "ms-danmu-panel",
                UiWidgets.SettingIconView.ICON_SUBTITLE,
                "高级弹幕引擎与屏蔽词设置",
                DanmuSettingsPanel.formatCompactStatus(DanmuSettingsPanel.loadConfig(a, false)),
                () -> {
                    android.app.Dialog dlg = DanmuSettingsPanel.showDialog(a, false, null);
                    dlg.setOnDismissListener(
                            d -> {
                                if (!a.isFinishing()
                                        && (android.os.Build.VERSION.SDK_INT < 17
                                                || !a.isDestroyed())) {
                                    reloadPage(shell);
                                }
                            });
                });
        addCoreToggle(
                a,
                body,
                "ms-danmaku-def",
                "播放时默认自动开启来源弹幕",
                Prefs.DANMAKU_DEFAULT,
                true,
                "已开启",
                "已关闭",
                null);
        addMobileIntPicker(
                shell,
                body,
                "ms-danmaku-style",
                "弹幕显示画面区域",
                Prefs.DANMAKU_AREA,
                new String[] {"顶部 1/4 屏 · 清爽", "半屏显示 · 推荐", "3/4 屏", "全屏铺满"},
                new int[] {0, 1, 2, 3},
                1);
        addMobileIntPicker(
                shell,
                body,
                "ms-danmaku-opacity",
                "弹幕文字不透明度",
                Prefs.DANMAKU_OPACITY,
                new String[] {"40% · 轻柔半透", "65% · 适中", "85% · 清晰推荐", "100% · 完全不透明"},
                new int[] {40, 65, 85, 100},
                85);
        addMobileIntPicker(
                shell,
                body,
                "ms-danmaku-speed",
                "弹幕飘屏速度",
                Prefs.DANMAKU_SPEED,
                new String[] {"慢速舒缓", "标准速度", "快速略过"},
                new int[] {0, 1, 2},
                1);
        List<OnlineSubtitleDanmakuService.DanmakuSource> dmList =
                OnlineSubtitleDanmakuService.loadDanmakuSources(a);
        addCard(
                a,
                body,
                "ms-danmaku-src",
                UiWidgets.SettingIconView.ICON_SPEED_GAUGE,
                "弹幕源管理与一键延迟测速排序",
                "已配置 " + dmList.size() + " 个自定义弹幕 API + 弹弹Play 官方接口",
                () -> showDanmakuSourcesDialog(shell));
    }

    // =========================================================================
    // GROUP 5: 刮削、账号与 AI 服务
    // =========================================================================
    private static void renderSubScrapingAccountsAndAi(MobileRootShell shell, LinearLayout body) {
        final MainActivity a = shell.a;
        sectionHeader(a, body, "TMDB 元数据刮削与多维评分");
        addCard(
                a,
                body,
                "ms-tmdb-cfg",
                UiWidgets.SettingIconView.ICON_TMDB_STAR,
                "TMDB API Key 与镜像反代配置",
                TmdbService.isConfigured(a)
                        ? ("已配置 · 语言 " + a.mobilePrefs().getString(Prefs.TMDB_LANGUAGE, "zh-CN"))
                        : "未配置 · 配置后解锁 TMDB 推荐首页、剧集剧照与 TheIntroDB 跳片头",
                () -> showTmdbConfigDialog(shell));

        boolean hasMdb =
                !a.secretsPrefs().getString(Prefs.SECRET_MDBLIST_API_KEY, "").trim().isEmpty();
        addCard(
                a,
                body,
                "ms-mdblist-cfg",
                UiWidgets.SettingIconView.ICON_TMDB_STAR,
                "MDBList 多平台评分密钥 (IMDb / 烂番茄 / Trakt)",
                hasMdb ? "已配置 MDBList API Key" : "可选配置 · 聚合展示国际影评站真实分值",
                () ->
                        promptSingleSecret(
                                shell,
                                "配置 MDBList API Key",
                                "前往 mdblist.com 免费获取个人 API Key（仅保存在本机加密偏好中）：",
                                Prefs.SECRET_MDBLIST_API_KEY));

        sectionHeader(a, body, "追剧日历与社区账号 (Bangumi / Trakt)");
        String bgmUser = a.secretsPrefs().getString(Prefs.SECRET_BANGUMI_USERNAME, "").trim();
        String traktTk = a.secretsPrefs().getString(Prefs.SECRET_TRAKT_TOKEN, "").trim();
        addCard(
                a,
                body,
                "ms-bgm-trakt",
                UiWidgets.SettingIconView.ICON_REPEAT_LOOP,
                "Bangumi 番组计划 / Trakt 追剧账号绑定",
                (!bgmUser.isEmpty() || !traktTk.isEmpty())
                        ? ("已绑定 "
                                + (!bgmUser.isEmpty() ? ("Bangumi:" + bgmUser + " ") : "")
                                + (!traktTk.isEmpty() ? "Trakt" : ""))
                        : "绑定后在「片库 → 追剧日历」同步个人在看番剧与美剧排期",
                () -> showTrackingAccountsDialog(shell));

        sectionHeader(a, body, "AI 大模型智能助手 (OpenAI 兼容)");
        addCard(
                a,
                body,
                "ms-ai-cfg",
                UiWidgets.SettingIconView.ICON_AI_SPARKLE,
                "AI 服务商、API Key 与模型配置",
                AiAssistantService.isConfigured(a)
                        ? ("已开启 · "
                                + AiAssistantService.providerLabel(
                                        a.mobilePrefs().getString(Prefs.AI_PROVIDER, "deepseek"))
                                + " ("
                                + AiAssistantService.resolveModel(a)
                                + ")")
                        : "支持 DeepSeek / 通义千问 / 硅基流动 / Kimi / GLM / 本地 Ollama",
                () -> showAiConfigDialog(shell));
        addMobileToggle(
                a,
                body,
                "ms-ai-clean-search",
                "聚合搜索结果片名净化",
                Prefs.AI_CLEAN_SEARCH,
                false,
                "已开启 · 自动剥离采集源防和谐符号与清晰度后缀",
                "关闭 · 保持片源返回原始标题",
                null);
        addMobileToggle(
                a,
                body,
                "ms-ai-py-audit",
                "导入 Python 爬虫源码安全扫描提醒",
                Prefs.AI_PY_SECURITY_CHECK,
                true,
                "已开启 · 自动检测高危系统命令调用",
                "已关闭",
                null);
    }

    // =========================================================================
    // GROUP 6: 云同步、网盘与隐私
    // =========================================================================
    private static void renderSubSyncAndTvConnect(MobileRootShell shell, LinearLayout body) {
        final MainActivity a = shell.a;
        sectionHeader(a, body, "云盘同步与网盘授权");
        addCard(
                a,
                body,
                "ms-cloud-sync",
                UiWidgets.SettingIconView.ICON_NETDISK,
                "WebDAV 云盘自动增量同步 & 局域网同步",
                CloudSyncDialog.statusSummary(a),
                () -> CloudSyncDialog.show(a, () -> reloadPage(shell)));
        addCard(
                a,
                body,
                "ms-netdisk",
                UiWidgets.SettingIconView.ICON_NETDISK,
                "网盘登录授权与优先级管理",
                "管理配置源提供的夸克 / 阿里 / 百度 / UC 网盘账号状态",
                () -> AccountPanel.show(a, null));
        addCard(
                a,
                body,
                "ms-alist",
                UiWidgets.SettingIconView.ICON_NETDISK,
                "AList 原生网盘挂载源管理",
                AlistAccounts.statusSummary(a),
                () -> AlistAccounts.openManager(a, () -> reloadPage(shell)));

        sectionHeader(a, body, "隐私保护与局域网互联");
        addCard(
                a,
                body,
                "ms-privacy",
                UiWidgets.SettingIconView.ICON_BACKUP_SAFE,
                a.privateMode ? "退出隐私空间（返回公开环境）" : "进入独立隐私空间",
                a.privateMode ? "当前处于加密隔离的隐私空间" : "使用 4 位数字口令开启独立隔离片源与历史空间",
                () -> PrivacySpace.openOrExit(a));
        addCard(
                a,
                body,
                "ms-spider-gw",
                UiWidgets.SettingIconView.ICON_PLUGIN_EXT,
                "Spider 局域网扩展共享网关",
                SpiderGatewayDialog.statusSummary(a),
                () -> SpiderGatewayDialog.show(a, () -> reloadPage(shell)));
        addCard(
                a,
                body,
                "ms-push-tv",
                UiWidgets.SettingIconView.ICON_LIVE_TV,
                "局域网跨设备推源",
                "将当前订阅源地址推送至同一 Wi-Fi 下的其他播放设备",
                () -> EditionImpl.showMobileLanTransferSheet(a));
    }

    // =========================================================================
    // GROUP 7: 存储、更新与关于
    // =========================================================================
    private static void renderSubStorageUpdateAndAbout(MobileRootShell shell, LinearLayout body) {
        final MainActivity a = shell.a;
        sectionHeader(a, body, "应用备份与恢复");
        addCard(
                a,
                body,
                "ms-backup-export",
                UiWidgets.SettingIconView.ICON_BACKUP_SAFE,
                "导出备份文件 (MarcoMovie-mobile-backup.json)",
                "包含片源、直播、收藏历史及界面设置（不含私密 API 密钥）",
                () -> BackupManager.pickDocument(a, 45, "application/json", true));
        addCard(
                a,
                body,
                "ms-backup-restore",
                UiWidgets.SettingIconView.ICON_BACKUP_SAFE,
                "从备份文件还原",
                "导入备份 JSON 恢复片源、片库与手机设置",
                () -> BackupManager.pickDocument(a, 46, "application/json", false));

        sectionHeader(a, body, "分项缓存管理");
        addCoreIntPicker(
                shell,
                body,
                "ms-disk-cache",
                "边播边存本地分块缓存上限",
                Prefs.MEDIA_CACHE_MB,
                new String[] {"关闭磁盘视频缓存", "128 MB", "256 MB · 推荐", "512 MB", "1024 MB"},
                new int[] {0, 128, 256, 512, 1024},
                256);

        long tmdbKb = TmdbService.cacheBytes(a) / 1024L;
        long aiKb = AiAssistantService.cacheBytes(a) / 1024L;
        addCard(
                a,
                body,
                "ms-clear-caches",
                UiWidgets.SettingIconView.ICON_TRASH_CLEAR,
                "分项缓存清理（海报 / TMDB / AI / 视频缓存）",
                "TMDB 缓存 " + tmdbKb + " KB  ·  AI 缓存 " + aiKb + " KB",
                () -> {
                    String[] opts = {
                        "清理海报内存与首页快照缓存",
                        "清理 TMDB 刮削与 TheIntroDB 缓存 (" + tmdbKb + " KB)",
                        "清理 AI 集名净化与字幕翻译缓存 (" + aiKb + " KB)",
                        "清空最近搜索关键词记录",
                        "一键清理以上全部临时缓存"
                    };
                    UiWidgets.showDrawerPicker(
                            a,
                            "分项清理本机缓存",
                            "不会删除你的订阅源、收藏夹、观看进度或离线下载视频",
                            opts,
                            4,
                            idx -> {
                                if (idx == 0 || idx == 4) {
                                    a.images.evictAll();
                                    a.homeData.clear();
                                }
                                if (idx == 1 || idx == 4) TmdbService.clearCache(a);
                                if (idx == 2 || idx == 4) AiAssistantService.clearCache(a);
                                if (idx == 3 || idx == 4) {
                                    a.prefs.edit().remove(Prefs.GLOBAL_SEARCH_HISTORY).apply();
                                }
                                a.toast("已完成所选缓存清理");
                                reloadPage(shell);
                            });
                });
        addCard(
                a,
                body,
                "ms-reset-mobile",
                UiWidgets.SettingIconView.ICON_REPEAT_LOOP,
                "恢复手机界面与手势默认偏好",
                "仅重置手机外观与手势设置，保留片源、历史收藏与 API 密钥",
                () ->
                        new AppDialog.Builder(a)
                                .setTitle("恢复手机默认偏好？")
                                .setMessage("将重置手机端界面、导航与播放手势设置，片源与收藏记录保持不变。")
                                .setNegativeButton("取消", null)
                                .setPositiveButton(
                                        "恢复默认",
                                        (d, w) -> {
                                            a.mobilePrefs().edit().clear().commit();
                                            a.recreate();
                                        })
                                .show());

        sectionHeader(a, body, "诊断、更新与开源声明");
        addCard(
                a,
                body,
                "ms-crash-reports",
                UiWidgets.SettingIconView.ICON_DIAGNOSTIC_LOG,
                "异常退出与崩溃报告诊断",
                "查看或导出历史异常堆栈，快速定位插件或解码问题",
                () -> CrashReportDialog.show(a, true));
        addCard(
                a,
                body,
                "ms-logs",
                UiWidgets.SettingIconView.ICON_DIAGNOSTIC_LOG,
                "查看运行诊断日志",
                "排查片源网络异常、解析器状态与播放内核告警",
                () -> {
                    String dump = AppLog.dump();
                    new AppDialog.Builder(a)
                            .setTitle("运行诊断日志")
                            .setMessage(dump.isEmpty() ? "当前运行正常，暂无异常日志。" : dump)
                            .setNeutralButton(
                                    "清空日志",
                                    (d, w) -> {
                                        AppLog.clear();
                                        a.toast("已清空诊断日志");
                                    })
                            .setPositiveButton("关闭", null)
                            .show();
                });
        addCard(
                a,
                body,
                "ms-updates",
                UiWidgets.SettingIconView.ICON_UPDATE_CLOUD,
                "检查软件更新（手机端独立通道）",
                "当前版本 v" + UpdateManager.installedVersion(a) + " · 仅匹配 android-mobile 安装包",
                () -> a.open(new MainActivity.Screen(() -> new UpdateScreen(a).show()), true));
        addCard(
                a,
                body,
                "ms-replay-onboarding",
                UiWidgets.SettingIconView.ICON_MOTION_SPARK,
                "重新查看新手引导",
                "回顾首次启动极光交互导览与声明",
                () -> {
                    OnboardingScreen.resetForReplay(a);
                    a.showOnboarding(true);
                });

        FrameLayout auroraBanner = new FrameLayout(a);
        auroraBanner.setBackground(a.bg(0xff0d1512, 18));
        UiCompat.setClipToOutline(auroraBanner, true);
        AuroraSurfaceView aurora = new AuroraSurfaceView(a);
        aurora.setReducedMotion(a.reduced);
        auroraBanner.addView(aurora, new FrameLayout.LayoutParams(-1, -1));
        TextView about =
                a.text(
                        "Marco Movie Mobile v"
                                + UpdateManager.installedVersion(a)
                                + " (GPL-3.0)\n"
                                + MainActivity.TOOL_DECLARATION,
                        12f,
                        MainActivity.WHITE);
        about.setLineSpacing(0, 1.38f);
        about.setPadding(a.dp(14), a.dp(14), a.dp(14), a.dp(14));
        auroraBanner.addView(about, new FrameLayout.LayoutParams(-1, -2));
        LinearLayout.LayoutParams abLp = new LinearLayout.LayoutParams(-1, -2);
        abLp.topMargin = a.dp(8);
        body.addView(auroraBanner, abLp);
    }

    // =========================================================================
    // CONFIGURATION DIALOGS FOR ONLINE SERVICES & PLAYER CUSTOMIZATION
    // =========================================================================
    private static void showTmdbConfigDialog(final MobileRootShell shell) {
        final MainActivity a = shell.a;
        final SharedPreferences mp = a.mobilePrefs();
        final SharedPreferences sec = a.secretsPrefs();

        LinearLayout form = a.vertical();
        form.setPadding(a.dp(4), a.dp(6), a.dp(4), a.dp(4));

        final EditText keyInput =
                formField(
                        a,
                        form,
                        "TMDB v3 API Key 或 v4 Read Token",
                        "填入你自己的 TMDB Key",
                        sec.getString(Prefs.SECRET_TMDB_API_KEY, ""),
                        true);
        final EditText apiProxyInput =
                formField(
                        a,
                        form,
                        "TMDB API 反代地址（可选，留空用官方 api.themoviedb.org）",
                        "https://…",
                        mp.getString(Prefs.TMDB_API_PROXY, ""),
                        false);
        final EditText imgProxyInput =
                formField(
                        a,
                        form,
                        "TMDB 图片反代地址（可选，留空用官方 image.tmdb.org）",
                        "https://…",
                        mp.getString(Prefs.TMDB_IMAGE_PROXY, ""),
                        false);

        final String[] langs = {"zh-CN", "zh-TW", "en-US"};
        final String[] curLang = {mp.getString(Prefs.TMDB_LANGUAGE, "zh-CN")};
        final TextView langBtn = a.text("刮削语言：" + curLang[0] + " ▾", 13f, Color.WHITE);
        langBtn.setPadding(a.dp(12), a.dp(9), a.dp(12), a.dp(9));
        langBtn.setBackground(a.bg(0xff1e2623, 10));
        UiWidgets.bindTouchFeedback(langBtn);
        langBtn.setOnClickListener(
                v -> {
                    int idx = Arrays.asList(langs).indexOf(curLang[0]);
                    UiWidgets.showDrawerPicker(
                            a,
                            "TMDB 元数据语言",
                            "",
                            new String[] {"简体中文 (zh-CN)", "繁體中文 (zh-TW)", "English (en-US)"},
                            Math.max(0, idx),
                            sel -> {
                                curLang[0] = langs[sel];
                                langBtn.setText("刮削语言：" + curLang[0] + " ▾");
                            });
                });
        form.addView(langBtn, new LinearLayout.LayoutParams(-1, -2));

        new AppDialog.Builder(a)
                .setTitle("配置 TMDB 刮削服务")
                .setView(wrapScroll(a, form))
                .setNegativeButton("取消", null)
                .setPositiveButton(
                        "保存",
                        (d, w) -> {
                            String apiP = apiProxyInput.getText().toString().trim();
                            String imgP = imgProxyInput.getText().toString().trim();
                            sec.edit()
                                    .putString(
                                            Prefs.SECRET_TMDB_API_KEY,
                                            keyInput.getText().toString().trim())
                                    .apply();
                            mp.edit()
                                    .putBoolean(Prefs.TMDB_ENABLED, true)
                                    .putString(
                                            Prefs.TMDB_API_PROXY,
                                            apiP.isEmpty()
                                                    ? ""
                                                    : (Prefs.sanitizeHttpUrl(apiP) == null
                                                            ? ""
                                                            : apiP))
                                    .putString(
                                            Prefs.TMDB_IMAGE_PROXY,
                                            imgP.isEmpty()
                                                    ? ""
                                                    : (Prefs.sanitizeHttpUrl(imgP) == null
                                                            ? ""
                                                            : imgP))
                                    .putString(Prefs.TMDB_LANGUAGE, curLang[0])
                                    .apply();
                            a.toast("TMDB 配置已保存");
                            reloadPage(shell);
                        })
                .show();
    }

    private static void showAiConfigDialog(final MobileRootShell shell) {
        final MainActivity a = shell.a;
        final SharedPreferences mp = a.mobilePrefs();
        final SharedPreferences sec = a.secretsPrefs();

        LinearLayout form = a.vertical();
        form.setPadding(a.dp(4), a.dp(6), a.dp(4), a.dp(4));

        final String[] curProv = {mp.getString(Prefs.AI_PROVIDER, "deepseek")};
        final TextView provBtn =
                a.text(
                        "服务商：" + AiAssistantService.providerLabel(curProv[0]) + " ▾",
                        13.5f,
                        Color.WHITE);
        provBtn.setTypeface(null, Typeface.BOLD);
        provBtn.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
        provBtn.setBackground(a.bg(0xff1e2623, 10));
        form.addView(provBtn, new LinearLayout.LayoutParams(-1, -2));
        a.gap(form, 8);

        final EditText keyInput =
                formField(
                        a,
                        form,
                        "API Key（本地 Ollama 可留空）",
                        "sk-…",
                        sec.getString(Prefs.SECRET_AI_API_KEY, ""),
                        true);
        final EditText baseInput =
                formField(
                        a,
                        form,
                        "接口地址 Base URL（留空使用所选服务商默认官方端点）",
                        AiAssistantService.defaultBaseUrl(curProv[0]),
                        mp.getString(Prefs.AI_BASE_URL, ""),
                        false);
        final EditText modelInput =
                formField(
                        a,
                        form,
                        "模型名称 Model（留空使用推荐默认模型）",
                        AiAssistantService.defaultModel(curProv[0]),
                        mp.getString(Prefs.AI_MODEL, ""),
                        false);

        UiWidgets.bindTouchFeedback(provBtn);
        provBtn.setOnClickListener(
                v -> {
                    int idx = Arrays.asList(AiAssistantService.PROVIDER_IDS).indexOf(curProv[0]);
                    UiWidgets.showDrawerPicker(
                            a,
                            "选择 AI 大模型服务商",
                            "均采用标准 OpenAI /chat/completions 兼容协议",
                            AiAssistantService.PROVIDER_LABELS,
                            Math.max(0, idx),
                            sel -> {
                                curProv[0] = AiAssistantService.PROVIDER_IDS[sel];
                                provBtn.setText(
                                        "服务商："
                                                + AiAssistantService.providerLabel(curProv[0])
                                                + " ▾");
                                baseInput.setHint(AiAssistantService.defaultBaseUrl(curProv[0]));
                                modelInput.setHint(AiAssistantService.defaultModel(curProv[0]));
                            });
                });

        final Runnable persist =
                () -> {
                    String keyVal = keyInput.getText().toString().trim();
                    String baseVal = baseInput.getText().toString().trim();
                    sec.edit().putString(Prefs.SECRET_AI_API_KEY, keyVal).apply();
                    mp.edit()
                            .putBoolean(
                                    Prefs.AI_ENABLED,
                                    !keyVal.isEmpty() || "ollama".equals(curProv[0]))
                            .putString(Prefs.AI_PROVIDER, curProv[0])
                            .putString(
                                    Prefs.AI_BASE_URL,
                                    baseVal.isEmpty() || Prefs.sanitizeHttpUrl(baseVal) == null
                                            ? ""
                                            : baseVal)
                            .putString(Prefs.AI_MODEL, modelInput.getText().toString().trim())
                            .apply();
                };

        new AppDialog.Builder(a)
                .setTitle("配置 AI 智能助手")
                .setView(wrapScroll(a, form))
                .setNegativeButton("关闭", null)
                .setNeutralButton(
                        "测试连接",
                        (d, w) -> {
                            persist.run();
                            a.toast("正在请求大模型测试连通性…");
                            AiAssistantService.testConnectionAsync(a, a::toast);
                        })
                .setPositiveButton(
                        "保存启用",
                        (d, w) -> {
                            persist.run();
                            a.toast("AI 大模型设置已保存");
                            reloadPage(shell);
                        })
                .show();
    }

    private static void showTrackingAccountsDialog(final MobileRootShell shell) {
        final MainActivity a = shell.a;
        final SharedPreferences sec = a.secretsPrefs();
        LinearLayout form = a.vertical();
        form.setPadding(a.dp(4), a.dp(6), a.dp(4), a.dp(4));

        final EditText bgmUser =
                formField(
                        a,
                        form,
                        "Bangumi 用户名 / UID（同步「在看」番剧列表）",
                        "例如：sai",
                        sec.getString(Prefs.SECRET_BANGUMI_USERNAME, ""),
                        false);
        final EditText bgmToken =
                formField(
                        a,
                        form,
                        "Bangumi Access Token（可选，读取私有收藏需要）",
                        "Bearer Token",
                        sec.getString(Prefs.SECRET_BANGUMI_TOKEN, ""),
                        true);
        final EditText traktId =
                formField(
                        a,
                        form,
                        "Trakt Client ID（可选）",
                        "Trakt API Client ID",
                        sec.getString(Prefs.SECRET_TRAKT_CLIENT_ID, ""),
                        false);
        final EditText traktToken =
                formField(
                        a,
                        form,
                        "Trakt Access Token（可选）",
                        "Trakt OAuth Access Token",
                        sec.getString(Prefs.SECRET_TRAKT_TOKEN, ""),
                        true);

        new AppDialog.Builder(a)
                .setTitle("追剧日历账号配置")
                .setView(wrapScroll(a, form))
                .setNegativeButton("取消", null)
                .setPositiveButton(
                        "保存",
                        (d, w) -> {
                            sec.edit()
                                    .putString(
                                            Prefs.SECRET_BANGUMI_USERNAME,
                                            bgmUser.getText().toString().trim())
                                    .putString(
                                            Prefs.SECRET_BANGUMI_TOKEN,
                                            bgmToken.getText().toString().trim())
                                    .putString(
                                            Prefs.SECRET_TRAKT_CLIENT_ID,
                                            traktId.getText().toString().trim())
                                    .putString(
                                            Prefs.SECRET_TRAKT_TOKEN,
                                            traktToken.getText().toString().trim())
                                    .apply();
                            a.toast("追剧账号已保存");
                            reloadPage(shell);
                        })
                .show();
    }

    private static void showOnlineSubtitleCredentialDialog(final MobileRootShell shell) {
        final MainActivity a = shell.a;
        final SharedPreferences sec = a.secretsPrefs();
        LinearLayout form = a.vertical();
        form.setPadding(a.dp(4), a.dp(6), a.dp(4), a.dp(4));

        final EditText assrt =
                formField(
                        a,
                        form,
                        "射手网(伪) Assrt API Token (assrt.net 个人中心获取)",
                        "32位 Token",
                        sec.getString(Prefs.SECRET_ASSRT_TOKEN, ""),
                        true);
        final EditText osKey =
                formField(
                        a,
                        form,
                        "OpenSubtitles REST v1 API Key (opensubtitles.com)",
                        "API Key",
                        sec.getString(Prefs.SECRET_OPENSUBTITLES_KEY, ""),
                        true);

        new AppDialog.Builder(a)
                .setTitle("在线字幕站凭据")
                .setView(wrapScroll(a, form))
                .setNegativeButton("取消", null)
                .setPositiveButton(
                        "保存",
                        (d, w) -> {
                            sec.edit()
                                    .putString(
                                            Prefs.SECRET_ASSRT_TOKEN,
                                            assrt.getText().toString().trim())
                                    .putString(
                                            Prefs.SECRET_OPENSUBTITLES_KEY,
                                            osKey.getText().toString().trim())
                                    .apply();
                            a.toast("在线字幕凭据已保存在本机");
                            reloadPage(shell);
                        })
                .show();
    }

    private static void showDanmakuSourcesDialog(final MobileRootShell shell) {
        final MainActivity a = shell.a;
        final List<OnlineSubtitleDanmakuService.DanmakuSource> list =
                OnlineSubtitleDanmakuService.loadDanmakuSources(a);
        LinearLayout box = a.vertical();
        box.setPadding(a.dp(4), a.dp(6), a.dp(4), a.dp(4));

        if (list.isEmpty()) {
            box.addView(
                    a.text("尚未添加自定义 LogVar 兼容弹幕源（默认使用弹弹Play 搜索接口）。", 12.5f, MainActivity.MUTED));
        } else {
            for (int i = 0; i < list.size(); i++) {
                final int idx = i;
                OnlineSubtitleDanmakuService.DanmakuSource s = list.get(i);
                LinearLayout r = a.row();
                r.setGravity(Gravity.CENTER_VERTICAL);
                r.setPadding(a.dp(10), a.dp(8), a.dp(10), a.dp(8));
                r.setBackground(a.bg(0xff1b2320, 10));
                String lat =
                        s.latencyMs > 0
                                ? (s.latencyMs >= 9999 ? "超时" : (s.latencyMs + "ms"))
                                : "未测速";
                TextView tv =
                        a.text(
                                (i + 1) + ". " + s.name + " (" + lat + ")\n" + s.baseUrl,
                                12f,
                                Color.WHITE);
                r.addView(tv, new LinearLayout.LayoutParams(0, -2, 1f));
                TextView del = a.text("删除", 12f, 0xffef4444);
                del.setPadding(a.dp(8), a.dp(4), a.dp(4), a.dp(4));
                del.setOnClickListener(
                        v -> {
                            list.remove(idx);
                            OnlineSubtitleDanmakuService.saveDanmakuSources(a, list);
                            reloadPage(shell);
                        });
                r.addView(del);
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
                lp.bottomMargin = a.dp(6);
                box.addView(r, lp);
            }
        }
        a.gap(box, 10);
        final EditText nameIn = formField(a, box, "新增弹幕源名称", "例如：自建弹幕库", "", false);
        final EditText urlIn =
                formField(
                        a, box, "弹幕 API 根地址 (兼容 /api/v2/search/episodes)", "https://…", "", false);

        new AppDialog.Builder(a)
                .setTitle("弹幕源管理与测速")
                .setView(wrapScroll(a, box))
                .setNegativeButton("关闭", null)
                .setNeutralButton(
                        "一键测速排序",
                        (d, w) -> {
                            a.toast("正在并发测速全部弹幕源…");
                            OnlineSubtitleDanmakuService.benchmarkDanmakuSourcesAsync(
                                    a,
                                    sorted -> {
                                        a.toast("已按响应延迟从快到慢完成自动排序");
                                        reloadPage(shell);
                                    });
                        })
                .setPositiveButton(
                        "添加弹幕源",
                        (d, w) -> {
                            String u = Prefs.sanitizeHttpUrl(urlIn.getText().toString().trim());
                            if (u == null || u.isEmpty()) {
                                a.toast("请输入有效的 HTTP / HTTPS 弹幕源地址");
                                return;
                            }
                            String n = nameIn.getText().toString().trim();
                            list.add(
                                    new OnlineSubtitleDanmakuService.DanmakuSource(
                                            n.isEmpty() ? "弹幕源 " + (list.size() + 1) : n,
                                            u,
                                            true,
                                            -1));
                            OnlineSubtitleDanmakuService.saveDanmakuSources(a, list);
                            a.toast("已添加弹幕源");
                            reloadPage(shell);
                        })
                .show();
    }

    private static void showCornerHudConfigSheet(final MobileRootShell shell) {
        final MainActivity a = shell.a;
        final int[] mask = {a.mobilePrefs().getInt(Prefs.PLAYER_CORNER_HUD, 7)};
        final int[] flags = {
            Prefs.HUD_CLOCK,
            Prefs.HUD_BATTERY,
            Prefs.HUD_NET_SPEED,
            Prefs.HUD_RESOLUTION,
            Prefs.HUD_FPS
        };
        final String[] names = {
            "系统时间 (HH:mm)", "电池电量 (%)", "实时网速 (KB/s · MB/s)", "视频分辨率", "实时帧率 (FPS)"
        };

        LinearLayout list = a.vertical();
        list.setPadding(a.dp(4), a.dp(6), a.dp(4), a.dp(4));
        for (int i = 0; i < flags.length; i++) {
            final int bit = flags[i];
            boolean on = (mask[0] & bit) != 0;
            LinearLayout row = a.row();
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
            row.setBackground(a.bg(0xff1b2320, 12));
            TextView lbl = a.text(names[i], 14f, Color.WHITE);
            row.addView(lbl, new LinearLayout.LayoutParams(0, -2, 1f));
            final UiWidgets.IosSwitchView sw = new UiWidgets.IosSwitchView(a, on);
            row.addView(sw, new LinearLayout.LayoutParams(a.dp(48), a.dp(28)));
            row.setOnClickListener(
                    v -> {
                        boolean next = !sw.isChecked();
                        sw.setChecked(next, !a.reduced);
                        if (next) mask[0] |= bit;
                        else mask[0] &= ~bit;
                    });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
            lp.bottomMargin = a.dp(8);
            list.addView(row, lp);
        }

        new AppDialog.Builder(a)
                .setTitle("播放页角落常驻信息")
                .setView(list)
                .setNegativeButton("取消", null)
                .setPositiveButton(
                        "保存",
                        (d, w) -> {
                            a.mobilePrefs().edit().putInt(Prefs.PLAYER_CORNER_HUD, mask[0]).apply();
                            reloadPage(shell);
                        })
                .show();
    }

    private static void showPlayerButtonOrderDialog(final MobileRootShell shell) {
        final MainActivity a = shell.a;
        String raw =
                Prefs.sanitizeButtonOrder(
                        a.mobilePrefs()
                                .getString(
                                        Prefs.PLAYER_BUTTON_ORDER,
                                        Prefs.DEFAULT_PLAYER_BUTTON_ORDER));
        final List<String> tokens = new ArrayList<>(Arrays.asList(raw.split(",")));

        final LinearLayout list = a.vertical();
        list.setPadding(a.dp(4), a.dp(6), a.dp(4), a.dp(4));

        final Runnable[] rebuild = new Runnable[1];
        rebuild[0] =
                () -> {
                    list.removeAllViews();
                    for (int i = 0; i < tokens.size(); i++) {
                        final int idx = i;
                        String tk = tokens.get(i);
                        LinearLayout r = a.row();
                        r.setGravity(Gravity.CENTER_VERTICAL);
                        r.setPadding(a.dp(12), a.dp(8), a.dp(8), a.dp(8));
                        r.setBackground(a.bg(0xff1b2320, 10));
                        r.addView(
                                a.text((i + 1) + ". " + buttonDisplayName(tk), 13.5f, Color.WHITE),
                                new LinearLayout.LayoutParams(0, -2, 1f));
                        if (i > 0) {
                            TextView up = a.text("↑ 上移", 12f, a.mobileAccentColor());
                            up.setPadding(a.dp(8), a.dp(4), a.dp(8), a.dp(4));
                            up.setOnClickListener(
                                    v -> {
                                        String tmp = tokens.set(idx - 1, tokens.get(idx));
                                        tokens.set(idx, tmp);
                                        rebuild[0].run();
                                    });
                            r.addView(up);
                        }
                        if (i < tokens.size() - 1) {
                            TextView dn = a.text("↓ 下移", 12f, 0xff93c5fd);
                            dn.setPadding(a.dp(8), a.dp(4), a.dp(8), a.dp(4));
                            dn.setOnClickListener(
                                    v -> {
                                        String tmp = tokens.set(idx + 1, tokens.get(idx));
                                        tokens.set(idx, tmp);
                                        rebuild[0].run();
                                    });
                            r.addView(dn);
                        }
                        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
                        lp.bottomMargin = a.dp(6);
                        list.addView(r, lp);
                    }
                };
        rebuild[0].run();

        new AppDialog.Builder(a)
                .setTitle("播放工具栏按钮排序")
                .setView(wrapScroll(a, list))
                .setNegativeButton("取消", null)
                .setNeutralButton(
                        "恢复默认顺序",
                        (d, w) -> {
                            a.mobilePrefs()
                                    .edit()
                                    .putString(
                                            Prefs.PLAYER_BUTTON_ORDER,
                                            Prefs.DEFAULT_PLAYER_BUTTON_ORDER)
                                    .apply();
                            a.toast("已恢复默认按钮顺序");
                        })
                .setPositiveButton(
                        "保存顺序",
                        (d, w) -> {
                            StringBuilder sb = new StringBuilder();
                            for (int i = 0; i < tokens.size(); i++) {
                                if (i > 0) sb.append(',');
                                sb.append(tokens.get(i));
                            }
                            a.mobilePrefs()
                                    .edit()
                                    .putString(
                                            Prefs.PLAYER_BUTTON_ORDER,
                                            Prefs.sanitizeButtonOrder(sb.toString()))
                                    .apply();
                            a.toast("已更新播放工具栏按钮顺序");
                        })
                .show();
    }

    private static String buttonDisplayName(String token) {
        if ("episodes".equals(token)) return "选集";
        if ("lines".equals(token)) return "换源 / 线路";
        if ("speed".equals(token)) return "播放倍速";
        if ("subtitles".equals(token)) return "内嵌与本地字幕";
        if ("online-sub".equals(token)) return "在线字幕搜索";
        if ("ai-sub".equals(token)) return "AI 双语字幕翻译";
        if ("danmaku-tool".equals(token)) return "弹幕开关与匹配";
        if ("aspect".equals(token)) return "画面比例";
        if ("decoder".equals(token)) return "内核与解码方式";
        if ("pip-tool".equals(token)) return "画中画小窗 (PiP)";
        if ("external-player".equals(token)) return "外部播放器打开";
        if ("more".equals(token)) return "更多工具";
        return token;
    }

    private static String describeHudMask(int mask) {
        if (mask <= 0) return "已关闭全部角落状态角标";
        List<String> on = new ArrayList<>();
        if ((mask & Prefs.HUD_CLOCK) != 0) on.add("时间");
        if ((mask & Prefs.HUD_BATTERY) != 0) on.add("电量");
        if ((mask & Prefs.HUD_NET_SPEED) != 0) on.add("实时网速");
        if ((mask & Prefs.HUD_RESOLUTION) != 0) on.add("分辨率");
        if ((mask & Prefs.HUD_FPS) != 0) on.add("帧率");
        StringBuilder sb = new StringBuilder("常驻展示：");
        for (int i = 0; i < on.size(); i++) {
            if (i > 0) sb.append(" · ");
            sb.append(on.get(i));
        }
        return sb.toString();
    }

    private static void promptSingleSecret(
            final MobileRootShell shell, String title, String tip, final String secretKey) {
        final MainActivity a = shell.a;
        LinearLayout box = a.vertical();
        box.setPadding(a.dp(4), a.dp(6), a.dp(4), a.dp(4));
        final EditText input =
                formField(a, box, tip, "API Key", a.secretsPrefs().getString(secretKey, ""), true);
        new AppDialog.Builder(a)
                .setTitle(title)
                .setView(box)
                .setNegativeButton("取消", null)
                .setPositiveButton(
                        "保存",
                        (d, w) -> {
                            a.secretsPrefs()
                                    .edit()
                                    .putString(secretKey, input.getText().toString().trim())
                                    .apply();
                            a.toast("密钥已保存");
                            reloadPage(shell);
                        })
                .show();
    }

    // =========================================================================
    // SHARED MOBILE SETTINGS UI BUILDERS & HIGHLIGHT FLASH
    // =========================================================================
    private static void sectionHeader(MainActivity a, LinearLayout parent, String text) {
        TextView h = a.text(text, 12.5f, a.mobileAccentColor());
        h.setTypeface(null, Typeface.BOLD);
        h.setPadding(a.dp(4), a.dp(10), a.dp(4), a.dp(8));
        parent.addView(h);
    }

    private static void addCard(
            MainActivity a,
            LinearLayout parent,
            String tagKey,
            int iconKind,
            String title,
            String subtitle,
            Runnable onTap) {
        LinearLayout row = a.row();
        row.setTag(tagKey);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(a.dp(16), a.dp(15), a.dp(16), a.dp(15));
        GradientDrawable normalBg =
                UiWidgets.glassBg(0xc01b2320, 0xc0131917, a.dp(18), a.dp(0.7f), 0x26ffffff);
        GradientDrawable pressedBg =
                UiWidgets.glassBg(0xd825322d, 0xd81b2420, a.dp(18), a.dp(0.9f), 0x48ffffff);
        row.setBackground(normalBg);
        UiWidgets.bindCardTouchFeedback(a, row, normalBg, pressedBg);
        row.setOnClickListener(v -> onTap.run());

        UiWidgets.SettingIconView icon = new UiWidgets.SettingIconView(a, iconKind);
        LinearLayout.LayoutParams iLp = new LinearLayout.LayoutParams(a.dp(38), a.dp(38));
        iLp.rightMargin = a.dp(13);
        row.addView(icon, iLp);

        LinearLayout col = a.vertical();
        TextView t = a.text(title, 14.5f, Color.WHITE);
        t.setTypeface(null, Typeface.BOLD);
        col.addView(t);
        if (subtitle != null && !subtitle.isEmpty()) {
            TextView s = a.text(subtitle, 12f, MainActivity.MUTED);
            s.setMaxLines(2);
            s.setEllipsize(TextUtils.TruncateAt.END);
            s.setPadding(0, a.dp(3), 0, 0);
            col.addView(s);
        }
        row.addView(col, new LinearLayout.LayoutParams(0, -2, 1f));
        row.addView(a.text("›", 19, MainActivity.MUTED));

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.bottomMargin = a.dp(11);
        parent.addView(row, lp);
    }

    private static void addMobileToggle(
            final MainActivity a,
            LinearLayout parent,
            String tagKey,
            String title,
            final String prefKey,
            boolean defVal,
            final String onSub,
            final String offSub,
            final Runnable after) {
        addToggleInternal(
                a, a.mobilePrefs(), parent, tagKey, title, prefKey, defVal, onSub, offSub, after);
    }

    private static void addCoreToggle(
            final MainActivity a,
            LinearLayout parent,
            String tagKey,
            String title,
            final String prefKey,
            boolean defVal,
            final String onSub,
            final String offSub,
            final Runnable after) {
        addToggleInternal(a, a.prefs, parent, tagKey, title, prefKey, defVal, onSub, offSub, after);
    }

    private static void addToggleInternal(
            final MainActivity a,
            final SharedPreferences sp,
            LinearLayout parent,
            String tagKey,
            String title,
            final String prefKey,
            boolean defVal,
            final String onSub,
            final String offSub,
            final Runnable after) {
        boolean init = sp.getBoolean(prefKey, defVal);
        LinearLayout row = a.row();
        row.setTag(tagKey);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(a.dp(16), a.dp(15), a.dp(16), a.dp(15));
        GradientDrawable normalBg =
                UiWidgets.glassBg(0xc01b2320, 0xc0131917, a.dp(18), a.dp(0.7f), 0x26ffffff);
        GradientDrawable pressedBg =
                UiWidgets.glassBg(0xd825322d, 0xd81b2420, a.dp(18), a.dp(0.9f), 0x48ffffff);
        row.setBackground(normalBg);
        UiWidgets.bindCardTouchFeedback(a, row, normalBg, pressedBg);

        UiWidgets.SettingIconView icon =
                new UiWidgets.SettingIconView(
                        a, UiWidgets.SettingIconView.kindForSetting(prefKey, title));
        LinearLayout.LayoutParams iLp = new LinearLayout.LayoutParams(a.dp(38), a.dp(38));
        iLp.rightMargin = a.dp(13);
        row.addView(icon, iLp);

        LinearLayout col = a.vertical();
        TextView t = a.text(title, 14.5f, Color.WHITE);
        t.setTypeface(null, Typeface.BOLD);
        col.addView(t);
        final TextView s = a.text(init ? onSub : offSub, 12f, MainActivity.MUTED);
        s.setPadding(0, a.dp(3), 0, 0);
        col.addView(s);
        row.addView(col, new LinearLayout.LayoutParams(0, -2, 1f));

        final UiWidgets.IosSwitchView sw = new UiWidgets.IosSwitchView(a, init);
        LinearLayout.LayoutParams swLp = new LinearLayout.LayoutParams(a.dp(50), a.dp(30));
        swLp.leftMargin = a.dp(10);
        row.addView(sw, swLp);

        row.setOnClickListener(
                v -> {
                    boolean next = !sw.isChecked();
                    sp.edit().putBoolean(prefKey, next).apply();
                    sw.setChecked(next, !a.reduced);
                    s.setText(next ? onSub : offSub);
                    if (after != null) after.run();
                });

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.bottomMargin = a.dp(11);
        parent.addView(row, lp);
    }

    private static void addMobileIntPicker(
            final MobileRootShell shell,
            LinearLayout parent,
            String tagKey,
            final String title,
            final String prefKey,
            final String[] labels,
            final int[] values,
            int fallback) {
        addIntPickerInternal(
                shell,
                shell.a.mobilePrefs(),
                parent,
                tagKey,
                title,
                prefKey,
                labels,
                values,
                fallback);
    }

    private static void addCoreIntPicker(
            final MobileRootShell shell,
            LinearLayout parent,
            String tagKey,
            final String title,
            final String prefKey,
            final String[] labels,
            final int[] values,
            int fallback) {
        addIntPickerInternal(
                shell, shell.a.prefs, parent, tagKey, title, prefKey, labels, values, fallback);
    }

    private static void addIntPickerInternal(
            final MobileRootShell shell,
            final SharedPreferences sp,
            LinearLayout parent,
            String tagKey,
            final String title,
            final String prefKey,
            final String[] labels,
            final int[] values,
            int fallback) {
        final MainActivity a = shell.a;
        int cur = sp.getInt(prefKey, fallback);
        int sel = 0;
        for (int i = 0; i < values.length; i++) if (values[i] == cur) sel = i;
        final int selectedIdx = sel;
        addCard(
                a,
                parent,
                tagKey,
                UiWidgets.SettingIconView.kindForSetting(prefKey, title),
                title,
                labels[selectedIdx],
                () ->
                        UiWidgets.showDrawerPicker(
                                a,
                                title,
                                "选择预设选项立即生效",
                                labels,
                                selectedIdx,
                                idx -> {
                                    sp.edit().putInt(prefKey, values[idx]).apply();
                                    if (Prefs.NAV_STYLE.equals(prefKey)
                                            || Prefs.ACCENT_PRESET.equals(prefKey)) {
                                        MobileRootShell.show(a);
                                    } else {
                                        reloadPage(shell);
                                    }
                                }));
    }

    private static EditText formField(
            MainActivity a,
            LinearLayout parent,
            String label,
            String hint,
            String initial,
            boolean password) {
        TextView lbl = a.text(label, 12f, MainActivity.MUTED);
        parent.addView(lbl);
        a.gap(parent, 5);
        EditText et = new EditText(a);
        et.setHint(hint);
        et.setHintTextColor(0xff6b7280);
        et.setTextColor(Color.WHITE);
        et.setTextSize(13.5f);
        et.setSingleLine(true);
        if (password) {
            et.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        }
        et.setPadding(a.dp(12), a.dp(9), a.dp(12), a.dp(9));
        et.setBackground(a.bg(0xff1e2623, 10));
        if (initial != null && !initial.isEmpty()) {
            et.setText(initial);
            et.setSelection(initial.length());
        }
        parent.addView(et, new LinearLayout.LayoutParams(-1, -2));
        a.gap(parent, 10);
        return et;
    }

    private static ScrollView wrapScroll(MainActivity a, View child) {
        ScrollView sv = new ScrollView(a);
        sv.setVerticalScrollBarEnabled(false);
        sv.addView(child, new ScrollView.LayoutParams(-1, -2));
        return sv;
    }

    /** Pulses an accent highlight border on the target card when jumped from Settings Search. */
    private static void flashSettingRow(final MainActivity a, final View row) {
        final int accent = a.mobileAccentColor();
        ValueAnimator anim = ValueAnimator.ofFloat(1f, 0.25f, 1f, 0f);
        anim.setDuration(1350);
        anim.addUpdateListener(
                va -> {
                    float f = (Float) va.getAnimatedValue();
                    int strokeAlpha = Math.round(230 * f) + 25;
                    int stroke = (strokeAlpha << 24) | (accent & 0x00ffffff);
                    int fillAlpha = 0xc0 + Math.round(0x28 * f);
                    row.setBackground(
                            UiWidgets.glassBg(
                                    (fillAlpha << 24) | 0x1e2c27,
                                    0xc8131917,
                                    a.dp(18),
                                    a.dp(1.6f),
                                    stroke));
                });
        anim.start();
    }
}
