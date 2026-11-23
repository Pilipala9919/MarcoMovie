package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * Apple tvOS-inspired split-view Live TV hub. Loads straight into the active/merged source with
 * instant snapshot caching, favorite channels, hidden-group management, QR-assisted channel search,
 * 2-column glass channel cards, and a live EPG preview inspector.
 */
final class TvV17LiveScreen {
    private static final int PAGE_SIZE = 48;
    private final MainActivity a;

    private List<LiveCatalog.Source> sources = new ArrayList<LiveCatalog.Source>();
    private int activeSourceIdx;
    private LiveCatalog.Catalog rawCatalog;
    private List<LiveCatalog.Group> displayGroups = new ArrayList<LiveCatalog.Group>();
    private int activeGroupIdx;
    private int activePage;
    private String searchQuery = "";
    private TvSearchContext context;
    private int loadSerial;

    // Pinned split-view UI slots
    private TextView headerStatusBadge;
    private TextView searchPillLabel;
    private TextView sourcePillLabel;
    private LinearLayout groupRail;
    private TvScrollView channelScroll;
    private LinearLayout channelPane;
    private TextView inspectorLogoMono;
    private ImageView inspectorLogoImg;
    private TextView inspectorFavBadge;
    private TextView inspectorTitle;
    private TextView inspectorNowLabel;
    private TextView inspectorNowTitle;
    private View inspectorProgressTrack;
    private View inspectorProgressFill;
    private TextView inspectorNextLabel;
    private TextView inspectorNextTitle;
    private LinearLayout inspectorTagsRow;
    private View firstChannelFocusTarget;
    private View activeGroupButton;
    private LiveCatalog.Channel inspectedChannel;

    TvV17LiveScreen(MainActivity activity) {
        a = activity;
    }

    void show() {
        a.renderPage("", "");
        context = new TvSearchContext(a.config, a.privateMode, a.engineEpoch);
        sources = LiveController.sourcesFor(a);

        if (a.scroll != null) a.root.removeView(a.scroll);

        LinearLayout shell = a.vertical();
        shell.setTag("v17-live-shell");
        shell.setClipChildren(false);
        shell.setClipToPadding(false);
        shell.setPadding(a.dp(48), a.dp(24), a.dp(48), a.dp(20));
        a.root.addView(shell, new FrameLayout.LayoutParams(-1, -1));

        buildHeader(shell);
        a.gap(shell, 16);

        if (sources.isEmpty()) {
            buildEmptyState(shell);
            return;
        }

        String lastUrl = a.prefs != null ? a.prefs.getString(Prefs.LIVE_LAST_SOURCE_URL, "") : "";
        activeSourceIdx = LivePreferences.resolveInitialSourceIndex(sources, lastUrl);
        buildSplitBody(shell);
        loadActiveSource(false);
    }

    private void buildHeader(LinearLayout shell) {
        LinearLayout header = a.row();
        header.setGravity(Gravity.CENTER_VERTICAL);
        header.setClipChildren(false);
        header.setClipToPadding(false);

        TextView title = a.text("电视直播", 30, TvV17Theme.TEXT);
        title.setTypeface(null, Typeface.BOLD);
        header.addView(title, new LinearLayout.LayoutParams(-2, -2));

        headerStatusBadge = a.text("准备就绪", 12, 0xccebebf5);
        headerStatusBadge.setSingleLine(true);
        headerStatusBadge.setEllipsize(TextUtils.TruncateAt.END);
        headerStatusBadge.setMaxWidth(a.dp(240));
        headerStatusBadge.setPadding(a.dp(12), a.dp(5), a.dp(12), a.dp(5));
        headerStatusBadge.setBackground(
                TvV17Surface.rounded(0x24ffffff, a.dp(999), 0x26ffffff, a.dp(1)));
        LinearLayout.LayoutParams badgeLp = new LinearLayout.LayoutParams(-2, -2);
        badgeLp.leftMargin = a.dp(14);
        header.addView(headerStatusBadge, badgeLp);

        header.addView(new View(a), new LinearLayout.LayoutParams(0, 1, 1f));

        if (!sources.isEmpty()) {
            if (sources.size() > 1) {
                LinearLayout srcBtn =
                        headerActionPill(
                                "切换源 ▾", "v17-live-switch-source", this::showSourcePickerDialog);
                sourcePillLabel = (TextView) srcBtn.getChildAt(0);
                addHeaderPill(header, srcBtn);
            }
            LinearLayout searchBtn =
                    headerActionPill("搜索频道", "v17-live-search", this::onSearchActionClicked);
            searchPillLabel = (TextView) searchBtn.getChildAt(0);
            addHeaderPill(header, searchBtn);

            addHeaderPill(
                    header,
                    headerActionPill(
                            "分组管理", "v17-live-manage-groups", this::showGroupManagerDialog));
            addHeaderPill(
                    header,
                    headerActionPill("刷新", "v17-live-refresh", () -> loadActiveSource(true)));
        }
        addHeaderPill(
                header,
                headerActionPill(
                        "＋ 导入源",
                        "v17-live-import",
                        () -> SourceController.showLiveImportDialog(a)));

        String clockText = new SimpleDateFormat("HH:mm", Locale.getDefault()).format(new Date());
        TextView clock = a.text(clockText, 15.5f, 0xb8ebebf5);
        clock.setTypeface(null, Typeface.BOLD);
        LinearLayout.LayoutParams clkLp = new LinearLayout.LayoutParams(-2, -2);
        clkLp.leftMargin = a.dp(14);
        header.addView(clock, clkLp);

        shell.addView(header, new LinearLayout.LayoutParams(-1, -2));
    }

    private void addHeaderPill(LinearLayout header, View pill) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, a.dp(36));
        lp.leftMargin = a.dp(8);
        header.addView(pill, lp);
    }

    private LinearLayout headerActionPill(String label, String tag, Runnable onClick) {
        LinearLayout pill = a.row();
        pill.setTag(tag);
        pill.setGravity(Gravity.CENTER);
        pill.setFocusable(true);
        pill.setFocusableInTouchMode(true);
        pill.setClickable(true);
        UiCompat.setDefaultFocusHighlightEnabled(pill, false);
        pill.setPadding(a.dp(14), 0, a.dp(14), 0);
        pill.setBackground(TvV17Surface.rounded(0x24ffffff, a.dp(999), 0x2cffffff, a.dp(1)));

        TextView tv = a.text(label, 12.5f, 0xebffffff);
        tv.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
        tv.setSingleLine(true);
        tv.setIncludeFontPadding(false);
        pill.addView(tv, new LinearLayout.LayoutParams(-2, -2));

        a.pressFeedback(pill);
        pill.setOnClickListener(v -> onClick.run());
        pill.setOnFocusChangeListener(
                (v, focused) -> {
                    FocusMotion.unclipAncestors(pill);
                    pill.setBackground(
                            TvV17Surface.rounded(
                                    focused ? 0xf8ffffff : 0x24ffffff,
                                    a.dp(999),
                                    focused ? 0xffffffff : 0x2cffffff,
                                    a.dp(1)));
                    tv.setTextColor(focused ? 0xff0b0e14 : 0xebffffff);
                    UiCompat.setElevation(pill, focused ? a.dp(8) : 0);
                    pill.animate()
                            .scaleX(focused ? 1.05f : 1f)
                            .scaleY(focused ? 1.05f : 1f)
                            .setDuration(a.reduced ? 0 : 120)
                            .start();
                });
        return pill;
    }

    private void buildEmptyState(LinearLayout shell) {
        FrameLayout centerHost = new FrameLayout(a);
        LinearLayout card = a.vertical();
        card.setGravity(Gravity.CENTER_HORIZONTAL);
        card.setPadding(a.dp(40), a.dp(36), a.dp(40), a.dp(34));
        card.setBackground(glassSurface(0x66141925, 22, 0x2cffffff));
        UiCompat.setElevation(card, a.dp(12));

        BroadcastGlyph emblem = new BroadcastGlyph(a, 0xff7cb8ff);
        card.addView(emblem, new LinearLayout.LayoutParams(a.dp(56), a.dp(56)));
        a.gap(card, 16);

        TextView heading = a.text("尚未添加电视直播源", 22, TvV17Theme.TEXT);
        heading.setTypeface(null, Typeface.BOLD);
        card.addView(heading);
        a.gap(card, 8);

        TextView sub =
                a.text(
                        "支持导入多份 M3U、TXT (#genre#) 与 JSON 直播源，自动聚合同名频道、支持 IPv6 优选、udpxy 组播转单播与 XMLTV 实时节目单。",
                        14,
                        TvV17Theme.MUTED);
        sub.setGravity(Gravity.CENTER);
        sub.setLineSpacing(a.dp(4), 1f);
        card.addView(sub);
        a.gap(card, 22);

        Button importBtn =
                a.navButton(
                        "＋ 导入电视直播源",
                        "v17-live-empty-import",
                        () -> SourceController.showLiveImportDialog(a));
        importBtn.setPadding(a.dp(28), a.dp(12), a.dp(28), a.dp(12));
        card.addView(importBtn, new LinearLayout.LayoutParams(-2, -2));

        centerHost.addView(card, new FrameLayout.LayoutParams(a.dp(560), -2, Gravity.CENTER));
        shell.addView(centerHost, new LinearLayout.LayoutParams(-1, 0, 1f));
        a.ui.post(importBtn::requestFocus);
    }

    private void buildSplitBody(LinearLayout shell) {
        LinearLayout columns = a.row();
        columns.setGravity(Gravity.TOP);
        columns.setClipChildren(false);
        columns.setClipToPadding(false);
        shell.addView(columns, new LinearLayout.LayoutParams(-1, 0, 1f));

        // Left rail: Channel Groups
        TvScrollView groupScroll = new TvScrollView(a);
        groupScroll.setVerticalScrollBarEnabled(false);
        groupScroll.setClipChildren(false);
        groupScroll.setClipToPadding(false);
        UiCompat.setDefaultFocusHighlightEnabled(groupScroll, false);
        groupRail = a.vertical();
        groupRail.setTag("v17-live-group-rail");
        groupRail.setClipChildren(false);
        groupRail.setClipToPadding(false);
        groupRail.setPadding(a.dp(2), a.dp(4), a.dp(6), a.dp(18));
        groupScroll.addView(groupRail, new ScrollView.LayoutParams(-1, -2));
        LinearLayout.LayoutParams leftLp = new LinearLayout.LayoutParams(a.dp(206), -1);
        leftLp.rightMargin = a.dp(20);
        columns.addView(groupScroll, leftLp);

        // Center stage: 2-column Glass Channel Grid
        channelScroll = new TvScrollView(a);
        channelScroll.setVerticalScrollBarEnabled(false);
        channelScroll.setClipChildren(false);
        channelScroll.setClipToPadding(false);
        UiCompat.setDefaultFocusHighlightEnabled(channelScroll, false);
        channelPane = a.vertical();
        channelPane.setTag("v17-live-channel-pane");
        channelPane.setClipChildren(false);
        channelPane.setClipToPadding(false);
        channelPane.setPadding(a.dp(4), a.dp(4), a.dp(8), a.dp(24));
        channelScroll.addView(channelPane, new ScrollView.LayoutParams(-1, -2));
        LinearLayout.LayoutParams centerLp = new LinearLayout.LayoutParams(0, -1, 1f);
        centerLp.rightMargin = a.dp(20);
        columns.addView(channelScroll, centerLp);

        // Right floating Inspector Preview Card
        LinearLayout inspector = buildInspectorCard();
        columns.addView(inspector, new LinearLayout.LayoutParams(a.dp(266), -2));
    }

    private LinearLayout buildInspectorCard() {
        LinearLayout card = a.vertical();
        card.setTag("v17-live-inspector");
        card.setPadding(a.dp(20), a.dp(20), a.dp(20), a.dp(18));
        card.setBackground(glassSurface(0x6b141925, 20, 0x2cffffff));
        UiCompat.setElevation(card, a.dp(10));

        LinearLayout topRow = a.row();
        topRow.setGravity(Gravity.CENTER_VERTICAL);

        FrameLayout logoSlot = new FrameLayout(a);
        logoSlot.setBackground(TvV17Surface.rounded(0x28ffffff, a.dp(14), 0x26ffffff, a.dp(1)));
        inspectorLogoMono = a.text("TV", 18, 0xffd6e4ff);
        inspectorLogoMono.setTypeface(null, Typeface.BOLD);
        inspectorLogoMono.setGravity(Gravity.CENTER);
        logoSlot.addView(inspectorLogoMono, new FrameLayout.LayoutParams(-1, -1));
        inspectorLogoImg = new ImageView(a);
        inspectorLogoImg.setScaleType(ImageView.ScaleType.FIT_CENTER);
        inspectorLogoImg.setPadding(a.dp(6), a.dp(6), a.dp(6), a.dp(6));
        logoSlot.addView(inspectorLogoImg, new FrameLayout.LayoutParams(-1, -1));
        LinearLayout.LayoutParams logoLp = new LinearLayout.LayoutParams(a.dp(56), a.dp(56));
        logoLp.rightMargin = a.dp(12);
        topRow.addView(logoSlot, logoLp);

        LinearLayout titleCol = a.vertical();
        LinearLayout pillRow = a.row();
        pillRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView liveDot = a.text("● LIVE", 10.5f, 0xffff6b6b);
        liveDot.setTypeface(null, Typeface.BOLD);
        liveDot.setPadding(a.dp(8), a.dp(2), a.dp(8), a.dp(2));
        liveDot.setBackground(TvV17Surface.rounded(0x26ff453a, a.dp(999), 0x44ff453a, a.dp(1)));
        pillRow.addView(liveDot);

        inspectorFavBadge = a.text("★ 已收藏", 10.5f, 0xfffbbf24);
        inspectorFavBadge.setTypeface(null, Typeface.BOLD);
        inspectorFavBadge.setPadding(a.dp(8), a.dp(2), a.dp(8), a.dp(2));
        inspectorFavBadge.setBackground(
                TvV17Surface.rounded(0x24fbbf24, a.dp(999), 0x44fbbf24, a.dp(1)));
        LinearLayout.LayoutParams favLp = new LinearLayout.LayoutParams(-2, -2);
        favLp.leftMargin = a.dp(6);
        inspectorFavBadge.setVisibility(View.GONE);
        pillRow.addView(inspectorFavBadge, favLp);
        titleCol.addView(pillRow);

        inspectorTitle = a.text("选择频道开始观看", 18, TvV17Theme.TEXT);
        inspectorTitle.setTypeface(null, Typeface.BOLD);
        inspectorTitle.setMaxLines(2);
        inspectorTitle.setEllipsize(TextUtils.TruncateAt.END);
        inspectorTitle.setPadding(0, a.dp(6), 0, 0);
        titleCol.addView(inspectorTitle);
        topRow.addView(titleCol, new LinearLayout.LayoutParams(0, -2, 1f));
        card.addView(topRow, new LinearLayout.LayoutParams(-1, -2));

        View divider = new View(a);
        divider.setBackgroundColor(0x1effffff);
        LinearLayout.LayoutParams divLp = new LinearLayout.LayoutParams(-1, Math.max(1, a.dp(1)));
        divLp.topMargin = a.dp(14);
        divLp.bottomMargin = a.dp(14);
        card.addView(divider, divLp);

        inspectorNowLabel = a.text("正在播出", 11.5f, 0xff7cb8ff);
        inspectorNowLabel.setTypeface(null, Typeface.BOLD);
        card.addView(inspectorNowLabel);

        inspectorNowTitle = a.text("暂无实时节目单", 14.5f, TvV17Theme.TEXT);
        inspectorNowTitle.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
        inspectorNowTitle.setMaxLines(2);
        inspectorNowTitle.setEllipsize(TextUtils.TruncateAt.END);
        inspectorNowTitle.setPadding(0, a.dp(4), 0, a.dp(8));
        card.addView(inspectorNowTitle);

        FrameLayout progressBar = new FrameLayout(a);
        inspectorProgressTrack = progressBar;
        progressBar.setBackground(TvV17Surface.rounded(0x24ffffff, a.dp(999), 0, 0));
        inspectorProgressFill = new View(a);
        inspectorProgressFill.setBackground(TvV17Surface.rounded(0xff60a5fa, a.dp(999), 0, 0));
        progressBar.addView(inspectorProgressFill, new FrameLayout.LayoutParams(0, -1));
        progressBar.setVisibility(View.GONE);
        LinearLayout.LayoutParams pbLp = new LinearLayout.LayoutParams(-1, a.dp(4));
        pbLp.bottomMargin = a.dp(12);
        card.addView(progressBar, pbLp);

        inspectorNextLabel = a.text("即将播出", 11.5f, TvV17Theme.MUTED);
        inspectorNextLabel.setVisibility(View.GONE);
        card.addView(inspectorNextLabel);

        inspectorNextTitle = a.text("", 13, 0xd4ebebf5);
        inspectorNextTitle.setMaxLines(2);
        inspectorNextTitle.setEllipsize(TextUtils.TruncateAt.END);
        inspectorNextTitle.setPadding(0, a.dp(3), 0, a.dp(12));
        inspectorNextTitle.setVisibility(View.GONE);
        card.addView(inspectorNextTitle);

        inspectorTagsRow = a.vertical();
        card.addView(inspectorTagsRow, new LinearLayout.LayoutParams(-1, -2));

        View divider2 = new View(a);
        divider2.setBackgroundColor(0x1affffff);
        LinearLayout.LayoutParams div2Lp = new LinearLayout.LayoutParams(-1, Math.max(1, a.dp(1)));
        div2Lp.topMargin = a.dp(14);
        div2Lp.bottomMargin = a.dp(10);
        card.addView(divider2, div2Lp);

        TextView legend = a.text("确认键 立即播放\n菜单键 / 长按 收藏或切换线路", 11.5f, 0x99ebebf5);
        legend.setLineSpacing(a.dp(3), 1f);
        card.addView(legend);
        return card;
    }

    private void loadActiveSource(boolean forceRefresh) {
        if (sources.isEmpty()) return;
        activeSourceIdx = Math.max(0, Math.min(activeSourceIdx, sources.size() - 1));
        final LiveCatalog.Source source = sources.get(activeSourceIdx);
        if (a.prefs != null && source.url != null) {
            a.prefs.edit().putString(Prefs.LIVE_LAST_SOURCE_URL, source.url).apply();
        }
        if (sourcePillLabel != null) {
            sourcePillLabel.setText(truncateLabel(source.name, 10) + " ▾");
        }
        headerStatusBadge.setText(
                forceRefresh ? "正在刷新 " + source.name + "…" : "正在加载 " + source.name + "…");

        if (!forceRefresh) {
            LiveCatalog.Catalog cached = LiveController.peekCachedCatalog(a, source);
            if (cached != null) {
                rawCatalog = cached;
                a.liveSession = new LiveSession(source, cached);
                a.liveSession.epgGuide = LiveController.peekCachedGuide(a, source);
                activeGroupIdx = 0;
                activePage = 0;
                rebuildDisplay();
                return;
            }
        }

        groupRail.removeAllViews();
        channelPane.removeAllViews();
        TextView loadingMsg = a.text("正在读取频道列表与节目单…", 15, TvV17Theme.MUTED);
        loadingMsg.setPadding(a.dp(12), a.dp(24), a.dp(12), a.dp(12));
        channelPane.addView(loadingMsg);

        final int serial = ++loadSerial;
        final int ticket = a.generation;
        a.submitPage(
                () -> {
                    try {
                        final LiveCatalog.Catalog loaded =
                                LiveController.loadCatalog(a, source, forceRefresh);
                        a.ui.post(
                                () -> {
                                    if (serial != loadSerial
                                            || ticket != a.generation
                                            || a.isFinishing()
                                            || !context.matches(
                                                    a.config, a.privateMode, a.engineEpoch)) {
                                        return;
                                    }
                                    rawCatalog = loaded;
                                    a.liveSession = new LiveSession(source, loaded);
                                    a.liveSession.epgGuide =
                                            LiveController.peekCachedGuide(a, source);
                                    activeGroupIdx = 0;
                                    activePage = 0;
                                    rebuildDisplay();
                                    if (forceRefresh) {
                                        a.toast("已刷新 " + loaded.channelCount() + " 个直播频道");
                                    }
                                });
                    } catch (final Exception err) {
                        a.ui.post(
                                () -> {
                                    if (serial != loadSerial
                                            || ticket != a.generation
                                            || a.isFinishing()) {
                                        return;
                                    }
                                    headerStatusBadge.setText("加载失败");
                                    channelPane.removeAllViews();
                                    LinearLayout errCard = a.vertical();
                                    errCard.setPadding(a.dp(24), a.dp(22), a.dp(24), a.dp(22));
                                    errCard.setBackground(glassSurface(0x661a1418, 18, 0x33ff6961));
                                    TextView msg =
                                            a.text("读取直播源失败：" + a.message(err), 15, 0xffffb4ad);
                                    errCard.addView(msg);
                                    a.gap(errCard, 14);
                                    Button retry =
                                            a.navButton(
                                                    "重新加载",
                                                    "v17-live-retry",
                                                    () -> loadActiveSource(true));
                                    errCard.addView(retry, new LinearLayout.LayoutParams(-2, -2));
                                    channelPane.addView(
                                            errCard, new LinearLayout.LayoutParams(-1, -2));
                                    a.ui.post(retry::requestFocus);
                                });
                    }
                });
    }

    private void rebuildDisplay() {
        if (rawCatalog == null) return;
        LiveCatalog.Source source = sources.get(activeSourceIdx);
        Set<String> favs = LivePreferences.loadFavorites(a);
        Set<String> blocked = LivePreferences.loadBlockedGroups(a);
        displayGroups = LivePreferences.buildDisplayGroups(rawCatalog, favs, blocked, searchQuery);

        int hiddenCount = blocked.size();
        String status =
                !searchQuery.isEmpty()
                        ? "搜索「"
                                + searchQuery
                                + "」· "
                                + (displayGroups.isEmpty()
                                        ? 0
                                        : displayGroups.get(0).channels.size())
                                + " 频道"
                        : source.name
                                + " · "
                                + rawCatalog.channelCount()
                                + " 频道"
                                + (hiddenCount > 0 ? "（隐藏 " + hiddenCount + " 类）" : "");
        headerStatusBadge.setText(status);
        if (searchPillLabel != null) {
            searchPillLabel.setText(searchQuery.isEmpty() ? "搜索频道" : "清除搜索 ×");
        }

        activeGroupIdx =
                displayGroups.isEmpty()
                        ? 0
                        : Math.max(0, Math.min(activeGroupIdx, displayGroups.size() - 1));
        renderGroupRail();
        renderChannelGrid(true);
    }

    private void renderGroupRail() {
        groupRail.removeAllViews();
        activeGroupButton = null;
        if (displayGroups.isEmpty()) {
            TextView empty = a.text("无可用分组", 13, TvV17Theme.MUTED);
            empty.setPadding(a.dp(12), a.dp(16), a.dp(12), a.dp(12));
            groupRail.addView(empty);
            return;
        }
        for (int i = 0; i < displayGroups.size(); i++) {
            final int gIdx = i;
            final LiveCatalog.Group group = displayGroups.get(i);
            final boolean isFavGroup = LivePreferences.FAVORITES_GROUP_NAME.equals(group.name);
            LinearLayout pill = a.row();
            pill.setTag("v17-live-group:" + i);
            pill.setGravity(Gravity.CENTER_VERTICAL);
            pill.setFocusable(true);
            pill.setFocusableInTouchMode(true);
            pill.setClickable(true);
            UiCompat.setDefaultFocusHighlightEnabled(pill, false);
            pill.setPadding(a.dp(14), a.dp(11), a.dp(12), a.dp(11));

            View dot = new View(a);
            LinearLayout.LayoutParams dotLp = new LinearLayout.LayoutParams(a.dp(6), a.dp(6));
            dotLp.rightMargin = a.dp(9);
            pill.addView(dot, dotLp);

            TextView label = a.text(group.name, 14, TvV17Theme.TEXT);
            label.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
            label.setSingleLine(true);
            label.setEllipsize(TextUtils.TruncateAt.END);
            pill.addView(label, new LinearLayout.LayoutParams(0, -2, 1f));

            TextView count = a.text(String.valueOf(group.channels.size()), 11.5f, TvV17Theme.MUTED);
            count.setPadding(a.dp(6), 0, 0, 0);
            pill.addView(count, new LinearLayout.LayoutParams(-2, -2));

            boolean selected = gIdx == activeGroupIdx;
            if (selected) activeGroupButton = pill;
            styleGroupPill(pill, dot, label, count, selected, false, isFavGroup);

            pill.setOnClickListener(
                    v -> {
                        if (activeGroupIdx != gIdx) {
                            activeGroupIdx = gIdx;
                            activePage = 0;
                            refreshGroupRailHighlights();
                            renderChannelGrid(false);
                        }
                        if (firstChannelFocusTarget != null) {
                            firstChannelFocusTarget.requestFocus();
                        }
                    });
            final boolean canHide =
                    !isFavGroup && !LivePreferences.SEARCH_GROUP_NAME.equals(group.name);
            final Runnable hideAction = canHide ? () -> confirmHideGroup(group.name) : null;
            final TvMenuAction.Release menuRelease = canHide ? new TvMenuAction.Release() : null;
            pill.setOnFocusChangeListener(
                    (v, focused) -> {
                        if (!focused && menuRelease != null) menuRelease.reset();
                        FocusMotion.unclipAncestors(pill);
                        if (focused && activeGroupIdx != gIdx) {
                            activeGroupIdx = gIdx;
                            activePage = 0;
                            activeGroupButton = pill;
                            refreshGroupRailHighlights();
                            renderChannelGrid(false);
                        } else {
                            styleGroupPill(
                                    pill,
                                    dot,
                                    label,
                                    count,
                                    gIdx == activeGroupIdx,
                                    focused,
                                    isFavGroup);
                        }
                    });
            pill.setOnKeyListener(
                    (v, keyCode, event) -> {
                        if (keyCode == KeyEvent.KEYCODE_DPAD_RIGHT
                                && event.getAction() == KeyEvent.ACTION_DOWN
                                && firstChannelFocusTarget != null) {
                            if (menuRelease != null) menuRelease.reset();
                            firstChannelFocusTarget.requestFocus();
                            return true;
                        }
                        if (canHide && keyCode == KeyEvent.KEYCODE_MENU) {
                            if (!v.hasFocus() || !v.isShown()) {
                                menuRelease.reset();
                                return true;
                            }
                            if (menuRelease.key(
                                    event.getAction(),
                                    event.getRepeatCount(),
                                    event.getDownTime(),
                                    event.isCanceled())) {
                                hideAction.run();
                            }
                            return true;
                        }
                        if (menuRelease != null) menuRelease.reset();
                        return false;
                    });
            if (canHide) {
                pill.setOnLongClickListener(
                        v -> {
                            hideAction.run();
                            return true;
                        });
            }
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, a.dp(44));
            lp.bottomMargin = a.dp(6);
            groupRail.addView(pill, lp);
        }
    }

    private void refreshGroupRailHighlights() {
        for (int i = 0; i < groupRail.getChildCount() && i < displayGroups.size(); i++) {
            View child = groupRail.getChildAt(i);
            if (!(child instanceof LinearLayout)) continue;
            LinearLayout pill = (LinearLayout) child;
            if (pill.getChildCount() < 3) continue;
            View dot = pill.getChildAt(0);
            TextView label = (TextView) pill.getChildAt(1);
            TextView count = (TextView) pill.getChildAt(2);
            boolean isFav = LivePreferences.FAVORITES_GROUP_NAME.equals(displayGroups.get(i).name);
            boolean selected = i == activeGroupIdx;
            if (selected) activeGroupButton = pill;
            styleGroupPill(pill, dot, label, count, selected, pill.hasFocus(), isFav);
        }
    }

    private void styleGroupPill(
            LinearLayout pill,
            View dot,
            TextView label,
            TextView count,
            boolean selected,
            boolean focused,
            boolean isFavGroup) {
        int bgColor = focused ? 0xf8ffffff : (selected ? 0x2cffffff : 0x12ffffff);
        int border = focused ? 0xffffffff : (selected ? 0x42ffffff : 0x00000000);
        pill.setBackground(TvV17Surface.rounded(bgColor, a.dp(13), border, a.dp(1)));
        label.setTextColor(
                focused
                        ? 0xff0b0e14
                        : (isFavGroup ? 0xfffbbf24 : (selected ? Color.WHITE : 0xccebebf5)));
        count.setTextColor(focused ? 0xff4b5563 : (selected ? 0xd9ffffff : 0x80ebebf5));
        int dotColor =
                focused
                        ? 0xff0a84ff
                        : (isFavGroup ? 0xfffbbf24 : (selected ? 0xff60a5fa : Color.TRANSPARENT));
        dot.setBackground(TvV17Surface.rounded(dotColor, a.dp(999), 0, 0));
        UiCompat.setElevation(pill, focused ? a.dp(8) : 0);
        pill.animate()
                .scaleX(focused ? 1.035f : 1f)
                .scaleY(focused ? 1.035f : 1f)
                .setDuration(a.reduced ? 0 : 110)
                .start();
    }

    private void renderChannelGrid(boolean moveInitialFocus) {
        channelPane.removeAllViews();
        firstChannelFocusTarget = null;
        if (channelScroll != null) channelScroll.scrollTo(0, 0);

        if (displayGroups.isEmpty()) {
            TextView empty = a.text("所有分组均已隐藏，点击顶部「分组管理」可恢复。", 15, TvV17Theme.MUTED);
            empty.setPadding(a.dp(12), a.dp(24), a.dp(12), a.dp(12));
            channelPane.addView(empty);
            updateInspector(null);
            return;
        }
        LiveCatalog.Group group = displayGroups.get(activeGroupIdx);
        if (group.channels.isEmpty()) {
            TextView empty =
                    a.text(
                            searchQuery.isEmpty() ? "此分组暂无频道。" : "没有找到匹配「" + searchQuery + "」的频道。",
                            15,
                            TvV17Theme.MUTED);
            empty.setPadding(a.dp(12), a.dp(24), a.dp(12), a.dp(12));
            channelPane.addView(empty);
            updateInspector(null);
            return;
        }

        int maxPage = (group.channels.size() - 1) / PAGE_SIZE;
        activePage = Math.max(0, Math.min(activePage, maxPage));
        int start = activePage * PAGE_SIZE;
        int end = Math.min(group.channels.size(), start + PAGE_SIZE);
        Set<String> favs = LivePreferences.loadFavorites(a);
        LiveCatalog.Source source = sources.get(activeSourceIdx);

        LinearLayout currentRow = null;
        for (int i = start; i < end; i++) {
            final int localIdx = i - start;
            if (localIdx % 2 == 0) {
                currentRow = a.row();
                currentRow.setClipChildren(false);
                currentRow.setClipToPadding(false);
                LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(-1, -2);
                rlp.bottomMargin = a.dp(10);
                channelPane.addView(currentRow, rlp);
            }
            final LiveCatalog.Channel ch = group.channels.get(i);
            final boolean isFav = LivePreferences.isFavorite(favs, ch);
            final boolean isLeftCol = (localIdx % 2 == 0);
            LinearLayout card = buildChannelCard(source, ch, i, isFav, isLeftCol);
            if (firstChannelFocusTarget == null) firstChannelFocusTarget = card;
            LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(0, a.dp(76), 1f);
            if (isLeftCol) clp.rightMargin = a.dp(10);
            currentRow.addView(card, clp);
        }
        if ((end - start) % 2 == 1 && currentRow != null) {
            currentRow.addView(new View(a), new LinearLayout.LayoutParams(0, 1, 1f));
        }

        if (maxPage > 0) {
            LinearLayout pager = a.row();
            pager.setGravity(Gravity.CENTER_VERTICAL);
            pager.setPadding(0, a.dp(6), 0, a.dp(6));
            if (activePage > 0) {
                Button prev =
                        a.navButton(
                                "← 上一页",
                                "v17-live-prev",
                                () -> {
                                    activePage--;
                                    renderChannelGrid(true);
                                });
                LinearLayout.LayoutParams plp = new LinearLayout.LayoutParams(-2, -2);
                plp.rightMargin = a.dp(10);
                pager.addView(prev, plp);
            }
            TextView pageInfo =
                    a.text(
                            "第 " + (activePage + 1) + " / " + (maxPage + 1) + " 页",
                            12.5f,
                            TvV17Theme.MUTED);
            LinearLayout.LayoutParams ilp = new LinearLayout.LayoutParams(-2, -2);
            ilp.rightMargin = a.dp(10);
            pager.addView(pageInfo, ilp);
            if (activePage < maxPage) {
                Button next =
                        a.navButton(
                                "下一页 →",
                                "v17-live-next",
                                () -> {
                                    activePage++;
                                    renderChannelGrid(true);
                                });
                pager.addView(next, new LinearLayout.LayoutParams(-2, -2));
            }
            channelPane.addView(pager, new LinearLayout.LayoutParams(-1, -2));
        }

        updateInspector(group.channels.get(start));
        if (moveInitialFocus && firstChannelFocusTarget != null) {
            final View target = firstChannelFocusTarget;
            a.ui.post(target::requestFocus);
        }
    }

    private LinearLayout buildChannelCard(
            final LiveCatalog.Source source,
            final LiveCatalog.Channel channel,
            int index,
            final boolean isFav,
            final boolean isLeftCol) {
        LinearLayout card = a.row();
        card.setTag("v17-live-channel:" + index);
        card.setGravity(Gravity.CENTER_VERTICAL);
        card.setFocusable(true);
        card.setFocusableInTouchMode(true);
        card.setClickable(true);
        UiCompat.setDefaultFocusHighlightEnabled(card, false);
        card.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
        card.setBackground(glassSurface(0x52151b27, 15, 0x22ffffff));

        // Logo / Monogram avatar
        FrameLayout logoBox = new FrameLayout(a);
        logoBox.setBackground(TvV17Surface.rounded(0x22ffffff, a.dp(11), 0x1effffff, a.dp(1)));
        TextView mono = a.text(LivePreferences.channelMonogram(channel.name), 13, 0xffd0e2ff);
        mono.setTypeface(null, Typeface.BOLD);
        mono.setGravity(Gravity.CENTER);
        logoBox.addView(mono, new FrameLayout.LayoutParams(-1, -1));
        if (channel.logo != null && !channel.logo.trim().isEmpty()) {
            ImageView logo = new ImageView(a);
            logo.setScaleType(ImageView.ScaleType.FIT_CENTER);
            logo.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(4));
            a.poster(channel.logo.trim(), logo);
            logoBox.addView(logo, new FrameLayout.LayoutParams(-1, -1));
        }
        LinearLayout.LayoutParams logoLp = new LinearLayout.LayoutParams(a.dp(42), a.dp(42));
        logoLp.rightMargin = a.dp(11);
        card.addView(logoBox, logoLp);

        // Channel title + EPG line
        LinearLayout copy = a.vertical();
        String titleStr = (isFav ? "★ " : "") + channel.name;
        TextView nameView = a.text(titleStr, 14.5f, TvV17Theme.TEXT);
        nameView.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
        nameView.setSingleLine(true);
        nameView.setEllipsize(TextUtils.TruncateAt.END);
        copy.addView(nameView);

        String epg = channel.options.get("epg");
        String subStr =
                epg != null && !epg.trim().isEmpty()
                        ? epg.trim()
                        : (channel.streams.size() > 1
                                ? channel.streams.size() + " 条高清备份线路"
                                : "实时直播流");
        TextView subView = a.text(subStr, 11.5f, 0x99ebebf5);
        subView.setSingleLine(true);
        subView.setEllipsize(TextUtils.TruncateAt.END);
        subView.setPadding(0, a.dp(3), 0, 0);
        copy.addView(subView);
        card.addView(copy, new LinearLayout.LayoutParams(0, -2, 1f));

        // Micro capability pill
        TextView metaPill = null;
        String metaLabel =
                LiveEpgService.supportsCatchup(channel)
                        ? "回看"
                        : (channel.streams.size() > 1 ? channel.streams.size() + "线" : "");
        if (!metaLabel.isEmpty()) {
            metaPill = a.text(metaLabel, 10.5f, 0xff8ec5ff);
            metaPill.setTypeface(null, Typeface.BOLD);
            metaPill.setPadding(a.dp(7), a.dp(3), a.dp(7), a.dp(3));
            metaPill.setBackground(TvV17Surface.rounded(0x2260a5fa, a.dp(999), 0, 0));
            LinearLayout.LayoutParams mpLp = new LinearLayout.LayoutParams(-2, -2);
            mpLp.leftMargin = a.dp(6);
            card.addView(metaPill, mpLp);
        }
        final TextView pillRef = metaPill;

        a.pressFeedback(card);
        card.setOnClickListener(v -> playChannelImmediate(source, channel));
        final Runnable menuAction = () -> showChannelContextMenu(source, channel);
        final TvMenuAction.Release menuRelease = new TvMenuAction.Release();
        card.setOnLongClickListener(
                v -> {
                    menuAction.run();
                    return true;
                });
        card.setOnFocusChangeListener(
                (v, focused) -> {
                    if (!focused) menuRelease.reset();
                    FocusMotion.unclipAncestors(card);
                    card.setBackground(
                            focused
                                    ? TvV17Surface.rounded(
                                            0xf8ffffff, a.dp(15), 0xffffffff, a.dp(1))
                                    : glassSurface(0x52151b27, 15, 0x22ffffff));
                    nameView.setTextColor(focused ? 0xff0b0e14 : TvV17Theme.TEXT);
                    subView.setTextColor(focused ? 0xff475569 : 0x99ebebf5);
                    logoBox.setBackground(
                            TvV17Surface.rounded(
                                    focused ? 0x140b0e14 : 0x22ffffff,
                                    a.dp(11),
                                    focused ? 0x220b0e14 : 0x1effffff,
                                    a.dp(1)));
                    mono.setTextColor(focused ? 0xff1e293b : 0xffd0e2ff);
                    if (pillRef != null) {
                        pillRef.setTextColor(focused ? 0xff0a84ff : 0xff8ec5ff);
                        pillRef.setBackground(
                                TvV17Surface.rounded(
                                        focused ? 0x1c0a84ff : 0x2260a5fa, a.dp(999), 0, 0));
                    }
                    UiCompat.setElevation(card, focused ? a.dp(10) : 0);
                    card.animate()
                            .scaleX(focused ? 1.03f : 1f)
                            .scaleY(focused ? 1.03f : 1f)
                            .setDuration(a.reduced ? 0 : 115)
                            .start();
                    if (focused) {
                        updateInspector(channel);
                    }
                });
        card.setOnKeyListener(
                (v, keyCode, event) -> {
                    if (isLeftCol
                            && keyCode == KeyEvent.KEYCODE_DPAD_LEFT
                            && event.getAction() == KeyEvent.ACTION_DOWN
                            && activeGroupButton != null) {
                        menuRelease.reset();
                        activeGroupButton.requestFocus();
                        return true;
                    }
                    if (keyCode == KeyEvent.KEYCODE_MENU) {
                        if (!v.hasFocus() || !v.isShown()) {
                            menuRelease.reset();
                            return true;
                        }
                        if (menuRelease.key(
                                event.getAction(),
                                event.getRepeatCount(),
                                event.getDownTime(),
                                event.isCanceled())) {
                            menuAction.run();
                        }
                        return true;
                    }
                    menuRelease.reset();
                    return false;
                });
        return card;
    }

    private void updateInspector(LiveCatalog.Channel channel) {
        inspectedChannel = channel;
        if (inspectorTitle == null) return;
        if (channel == null) {
            inspectorLogoMono.setText("TV");
            inspectorLogoImg.setImageDrawable(null);
            inspectorFavBadge.setVisibility(View.GONE);
            inspectorTitle.setText("选择频道开始观看");
            inspectorNowLabel.setText("正在播出");
            inspectorNowTitle.setText("暂无频道");
            inspectorProgressTrack.setVisibility(View.GONE);
            inspectorNextLabel.setVisibility(View.GONE);
            inspectorNextTitle.setVisibility(View.GONE);
            inspectorTagsRow.removeAllViews();
            return;
        }
        inspectorLogoMono.setText(LivePreferences.channelMonogram(channel.name));
        inspectorLogoImg.setImageDrawable(null);
        if (channel.logo != null && !channel.logo.trim().isEmpty()) {
            a.poster(channel.logo.trim(), inspectorLogoImg);
        }
        boolean fav = LivePreferences.isFavorite(LivePreferences.loadFavorites(a), channel);
        inspectorFavBadge.setVisibility(fav ? View.VISIBLE : View.GONE);
        inspectorTitle.setText(channel.name);

        // Live EPG + progress bar
        LiveEpgService.Program liveProg = null;
        if (a.liveSession != null && a.liveSession.epgGuide != null) {
            liveProg =
                    a.liveSession.epgGuide.currentProgram(
                            channel.id,
                            channel.options.get("tvg-name"),
                            channel.name,
                            System.currentTimeMillis());
        }
        String epgNow = channel.options.get("epg");
        if (liveProg != null && !liveProg.title.isEmpty()) {
            inspectorNowLabel.setText("正在播出 · " + liveProg.timeRangeLabel());
            inspectorNowTitle.setText(liveProg.title);
            float progress =
                    LivePreferences.computeEpgProgress(
                            liveProg.startMs, liveProg.stopMs, System.currentTimeMillis());
            if (progress >= 0f) {
                inspectorProgressTrack.setVisibility(View.VISIBLE);
                int trackW = a.dp(226);
                ViewGroup.LayoutParams flp = inspectorProgressFill.getLayoutParams();
                flp.width = Math.max(a.dp(6), Math.round(trackW * progress));
                inspectorProgressFill.setLayoutParams(flp);
            } else {
                inspectorProgressTrack.setVisibility(View.GONE);
            }
        } else if (epgNow != null && !epgNow.trim().isEmpty()) {
            inspectorNowLabel.setText("正在播出");
            inspectorNowTitle.setText(epgNow.trim());
            inspectorProgressTrack.setVisibility(View.GONE);
        } else {
            inspectorNowLabel.setText("节目单");
            inspectorNowTitle.setText("暂无实时 EPG（可在设置配置 XMLTV）");
            inspectorProgressTrack.setVisibility(View.GONE);
        }

        String nextEpg = channel.options.get("epg-next");
        if (nextEpg != null && !nextEpg.trim().isEmpty()) {
            inspectorNextLabel.setVisibility(View.VISIBLE);
            inspectorNextTitle.setVisibility(View.VISIBLE);
            inspectorNextTitle.setText(nextEpg.trim());
        } else {
            inspectorNextLabel.setVisibility(View.GONE);
            inspectorNextTitle.setVisibility(View.GONE);
        }

        inspectorTagsRow.removeAllViews();
        String[] labels = LiveController.streamLabelsFor(a, channel);
        if (labels.length > 0) {
            addInspectorMeta(inspectorTagsRow, "优选线路", labels[0], 0xff66d4cf);
        }
        if (labels.length > 1) {
            addInspectorMeta(
                    inspectorTagsRow, "备份线路", "共 " + labels.length + " 条，断流自动切换", 0xff93c5fd);
        }
        if (LiveEpgService.supportsCatchup(channel)) {
            addInspectorMeta(inspectorTagsRow, "回看时移", "支持（播放中按菜单打开）", 0xfffbbf24);
        }
    }

    private void addInspectorMeta(LinearLayout parent, String key, String value, int valueColor) {
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(0, a.dp(3), 0, a.dp(3));
        TextView k = a.text(key, 11.5f, TvV17Theme.MUTED);
        row.addView(k, new LinearLayout.LayoutParams(a.dp(58), -2));
        TextView v = a.text(value, 12f, valueColor);
        v.setSingleLine(true);
        v.setEllipsize(TextUtils.TruncateAt.END);
        row.addView(v, new LinearLayout.LayoutParams(0, -2, 1f));
        parent.addView(row, new LinearLayout.LayoutParams(-1, -2));
    }

    private void playChannelImmediate(LiveCatalog.Source source, LiveCatalog.Channel channel) {
        if (!context.matches(a.config, a.privateMode, a.engineEpoch)) {
            a.notice("来源已更改，请重新打开直播。");
            return;
        }
        if (channel == null || channel.streams.isEmpty()) {
            a.notice("此频道没有可播放的线路。");
            return;
        }
        LiveController.playFromCatalog(
                a, source, rawCatalog, channel, channel.streams.get(0), context);
    }

    private void showChannelContextMenu(
            final LiveCatalog.Source source, final LiveCatalog.Channel channel) {
        if (channel == null) return;
        boolean fav = LivePreferences.isFavorite(LivePreferences.loadFavorites(a), channel);
        List<String> items = new ArrayList<String>();
        items.add(fav ? "取消收藏此频道" : "★ 收藏到置顶「收藏频道」");
        if (channel.streams.size() > 1) {
            items.add("选择播放线路（共 " + channel.streams.size() + " 条）");
        }
        String curGroupName =
                activeGroupIdx >= 0 && activeGroupIdx < displayGroups.size()
                        ? displayGroups.get(activeGroupIdx).name
                        : "";
        final boolean canHideGroup =
                !curGroupName.isEmpty()
                        && !LivePreferences.FAVORITES_GROUP_NAME.equals(curGroupName)
                        && !LivePreferences.SEARCH_GROUP_NAME.equals(curGroupName);
        if (canHideGroup) {
            items.add("隐藏当前分组「" + curGroupName + "」");
        }
        new AppDialog.Builder(a)
                .setTitle(channel.name)
                .setItems(
                        items.toArray(new String[0]),
                        (d, which) -> {
                            if (which == 0) {
                                boolean nowFav = LivePreferences.toggleFavorite(a, channel);
                                a.toast(nowFav ? "已收藏频道：" + channel.name : "已取消收藏：" + channel.name);
                                rebuildDisplay();
                            } else if (which == 1 && channel.streams.size() > 1) {
                                showStreamPickerDialog(source, channel);
                            } else if (canHideGroup) {
                                confirmHideGroup(curGroupName);
                            }
                        })
                .setNegativeButton("取消", null)
                .show();
    }

    private void showStreamPickerDialog(
            final LiveCatalog.Source source, final LiveCatalog.Channel channel) {
        String[] labels = LiveController.streamLabelsFor(a, channel);
        new AppDialog.Builder(a)
                .setTitle(channel.name + " · 选择线路")
                .setItems(
                        labels,
                        (dialog, index) ->
                                LiveController.playFromCatalog(
                                        a,
                                        source,
                                        rawCatalog,
                                        channel,
                                        channel.streams.get(index),
                                        context))
                .setNegativeButton("取消", null)
                .show();
    }

    private void showSourcePickerDialog() {
        if (sources.size() <= 1) return;
        String[] names = new String[sources.size()];
        for (int i = 0; i < sources.size(); i++) {
            names[i] = (i == activeSourceIdx ? "✓  " : "     ") + sources.get(i).name;
        }
        new AppDialog.Builder(a)
                .setTitle("切换直播源")
                .setItems(
                        names,
                        (d, which) -> {
                            if (which != activeSourceIdx) {
                                activeSourceIdx = which;
                                searchQuery = "";
                                loadActiveSource(false);
                            }
                        })
                .setNegativeButton("取消", null)
                .show();
    }

    private void onSearchActionClicked() {
        if (!searchQuery.isEmpty()) {
            searchQuery = "";
            activeGroupIdx = 0;
            activePage = 0;
            rebuildDisplay();
            return;
        }
        LinearLayout box = a.vertical();
        box.setPadding(a.dp(4), a.dp(6), a.dp(4), a.dp(4));
        TextView tip = a.text("支持按频道名或当前节目名称检索（可点击右侧二维码图标手机扫码输入）：", 13, MainActivity.MUTED);
        box.addView(tip);
        a.gap(box, 10);
        final EditText input = new EditText(a);
        input.setSingleLine(true);
        input.setHint("例如：CCTV / 卫视 / 4K / 体育");
        input.setTextColor(MainActivity.WHITE);
        input.setHintTextColor(0xff6b7280);
        input.setTextSize(14.5f);
        input.setPadding(a.dp(14), a.dp(10), a.dp(14), a.dp(10));
        input.setBackground(a.bg(0xff242834, 12));
        box.addView(
                TvQrInputHelper.wrap(a, input, "搜索直播频道"), new LinearLayout.LayoutParams(-1, -2));
        new AppDialog.Builder(a)
                .setTitle("搜索直播频道")
                .setView(box)
                .setNegativeButton("取消", null)
                .setPositiveButton(
                        "搜索",
                        (d, w) -> {
                            searchQuery =
                                    input.getText() == null
                                            ? ""
                                            : input.getText().toString().trim();
                            activeGroupIdx = 0;
                            activePage = 0;
                            rebuildDisplay();
                        })
                .show();
    }

    private void confirmHideGroup(final String groupName) {
        new AppDialog.Builder(a)
                .setTitle("隐藏分组「" + groupName + "」？")
                .setMessage("隐藏后该分类下的频道将不再显示，可随时点击顶部「分组管理」恢复显示。")
                .setNegativeButton("取消", null)
                .setPositiveButton(
                        "隐藏分组",
                        (d, w) -> {
                            LivePreferences.toggleBlockedGroup(a, groupName);
                            a.toast("已隐藏分组：" + groupName);
                            activeGroupIdx = 0;
                            activePage = 0;
                            rebuildDisplay();
                        })
                .show();
    }

    private void showGroupManagerDialog() {
        if (rawCatalog == null || rawCatalog.groups.isEmpty()) {
            a.toast("当前直播源暂无可管理的分组");
            return;
        }
        Set<String> blocked = LivePreferences.loadBlockedGroups(a);
        final String[] labels = new String[rawCatalog.groups.size()];
        for (int i = 0; i < rawCatalog.groups.size(); i++) {
            LiveCatalog.Group g = rawCatalog.groups.get(i);
            boolean isBlocked = blocked.contains(g.name);
            labels[i] =
                    (isBlocked ? "✕ [已隐藏]  " : "✓  ") + g.name + "  (" + g.channels.size() + ")";
        }
        AppDialog.Builder b =
                new AppDialog.Builder(a)
                        .setTitle("频道分组显示管理（点击切换显示/隐藏）")
                        .setItems(
                                labels,
                                (d, which) -> {
                                    String gName = rawCatalog.groups.get(which).name;
                                    boolean nowHidden =
                                            LivePreferences.toggleBlockedGroup(a, gName);
                                    a.toast(nowHidden ? "已隐藏分组：" + gName : "已恢复显示：" + gName);
                                    activeGroupIdx = 0;
                                    activePage = 0;
                                    rebuildDisplay();
                                })
                        .setNegativeButton("完成", null);
        if (!blocked.isEmpty()) {
            b.setNeutralButton(
                    "全部恢复显示",
                    (d, w) -> {
                        LivePreferences.clearBlockedGroups(a);
                        a.toast("已恢复全部直播分组");
                        activeGroupIdx = 0;
                        activePage = 0;
                        rebuildDisplay();
                    });
        }
        b.show();
    }

    private GradientDrawable glassSurface(int fill, float radiusDp, int stroke) {
        boolean reducedTrans =
                a.prefs != null && a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
        int bg = reducedTrans ? TvV17Theme.OPAQUE_SURFACE : fill;
        return TvV17Surface.rounded(bg, a.dp(radiusDp), stroke, a.dp(1));
    }

    private static String truncateLabel(String text, int max) {
        if (text == null) return "";
        String t = text.trim();
        return t.length() <= max ? t : t.substring(0, max - 1) + "…";
    }

    /** Lightweight vector broadcast-signal emblem for the Live TV empty hero state. */
    private static final class BroadcastGlyph extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF arc = new RectF();

        BroadcastGlyph(Context ctx, int color) {
            super(ctx);
            paint.setColor(color);
            paint.setStrokeCap(Paint.Cap.ROUND);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth();
            int h = getHeight();
            if (w <= 0 || h <= 0) return;
            float cx = w * 0.5f;
            float cy = h * 0.54f;
            float r = Math.min(w, h) * 0.42f;

            paint.setStyle(Paint.Style.FILL);
            canvas.drawCircle(cx, cy, r * 0.16f, paint);

            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(Math.max(2.5f, r * 0.11f));
            for (float scale : new float[] {0.48f, 0.82f}) {
                float rad = r * scale;
                arc.set(cx - rad, cy - rad, cx + rad, cy + rad);
                canvas.drawArc(arc, -42f, 84f, false, paint);
                canvas.drawArc(arc, 138f, 84f, false, paint);
            }
            canvas.drawLine(cx, cy + r * 0.22f, cx, cy + r * 0.85f, paint);
            canvas.drawLine(cx - r * 0.36f, cy + r * 0.85f, cx + r * 0.36f, cy + r * 0.85f, paint);
        }
    }
}
