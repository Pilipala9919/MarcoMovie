package com.pilipala.marcomovie;

import android.content.Intent;
import android.graphics.*;
import android.net.Uri;
import android.view.Gravity;
import android.view.View;
import android.widget.*;
import com.pilipala.marcomovie.hud.PlayerHudPrefs;
import java.io.*;

/** Remote-friendly settings. Each row changes a setting consumed by the app. */
final class SettingsScreen {
    final MainActivity a;

    SettingsScreen(MainActivity activity) {
        a = activity;
    }

    void page(String title, String note) {
        a.renderPage("", "");
        if (a.isTvDevice() && a.scroll instanceof TvScrollView)
            ((TvScrollView) a.scroll).readingMode = true;
        if (a.isTvDevice()) {
            tvPage(title, note);
            return;
        }
        if (!a.isTvDevice()) {
            LinearLayout topNav = a.row();
            topNav.setGravity(Gravity.CENTER_VERTICAL);
            topNav.setPadding(0, 0, 0, a.dp(14));
            TextView backBtn = a.text("‹", 22, MainActivity.WHITE);
            backBtn.setGravity(Gravity.CENTER);
            backBtn.setBackground(
                    MobileShell.glassBg(0xb034343a, 0xc01e1e22, a.dp(999), a.dp(0.8f), 0x38ffffff));
            MobileDetailScreen.bindTouchFeedback(backBtn);
            backBtn.setOnClickListener(v -> a.onBackPressed());
            LinearLayout.LayoutParams backLp = new LinearLayout.LayoutParams(a.dp(38), a.dp(38));
            backLp.rightMargin = a.dp(10);
            topNav.addView(backBtn, backLp);
            TextView heading = a.text(title, 22, MainActivity.WHITE);
            heading.setTypeface(null, Typeface.BOLD);
            topNav.addView(heading, new LinearLayout.LayoutParams(0, -2, 1));
            a.body.addView(topNav, new LinearLayout.LayoutParams(-1, -2));
        } else {
            a.body.addView(a.text(title, 28, MainActivity.WHITE));
            a.gap(a.body, 10);
        }
        if (!note.isEmpty()) {
            a.paragraph(note);
            a.gap(a.body, 6);
        }
    }

    /** Apple tvOS-style split-view settings shell. Right pane hosts grouped focus-lifted cards. */
    static final int TV_CAT_APPEARANCE = 0;

    static final int TV_CAT_PLAYBACK = 1;
    static final int TV_CAT_CONTENT = 2;
    static final int TV_CAT_BACKUP = 3;
    static final int TV_CAT_UPDATES = 4;
    static final int TV_CAT_COUNT = 5;
    private static android.view.animation.DecelerateInterpolator tvDecelCache;

    private static android.view.animation.DecelerateInterpolator tvDecel() {
        if (tvDecelCache == null) {
            tvDecelCache = new android.view.animation.DecelerateInterpolator();
        }
        return tvDecelCache;
    }

    static int resolveTvCategoryIndex(String title) {
        if (title == null) return TV_CAT_APPEARANCE;
        if (title.equals("播放与字幕") || title.equals("解码组件")) return TV_CAT_PLAYBACK;
        if (title.equals("内容与连接") || title.equals("片源与直播")) return TV_CAT_CONTENT;
        if (title.equals("数据与备份") || title.equals("运行日志")) return TV_CAT_BACKUP;
        if (title.equals("软件更新")) return TV_CAT_UPDATES;
        return TV_CAT_APPEARANCE;
    }

    private View tvActiveCategoryButton;
    private View tvFirstRightControl;
    private FrameLayout tvRightHost;
    private TvScrollView tvActiveScroll;
    private int tvSelectedCategory = TV_CAT_APPEARANCE;
    private int tvBuildingCategory = -1;
    private final TvScrollView[] tvCategoryScrolls = new TvScrollView[TV_CAT_COUNT];
    private final LinearLayout[] tvCategoryPanes = new LinearLayout[TV_CAT_COUNT];
    private final View[] tvCategoryFirstControls = new View[TV_CAT_COUNT];
    private final java.util.List<Runnable> tvCategoryRefreshers = new java.util.ArrayList<>();
    private final android.util.SparseArray<View> tvCategoryViews = new android.util.SparseArray<>();

    void tvPage(String title, String note) {
        tvActiveCategoryButton = null;
        tvFirstRightControl = null;
        tvActiveScroll = null;
        tvBuildingCategory = -1;
        java.util.Arrays.fill(tvCategoryScrolls, null);
        java.util.Arrays.fill(tvCategoryPanes, null);
        java.util.Arrays.fill(tvCategoryFirstControls, null);
        tvCategoryRefreshers.clear();
        tvCategoryViews.clear();
        tvSelectedCategory = resolveTvCategoryIndex(title);

        // Replace outer page scroll with a fixed full-screen Apple tvOS split container so the
        // left primary navigation pane stays pinned while the right settings pane scrolls cleanly.
        if (a.scroll != null) a.root.removeView(a.scroll);

        LinearLayout shell = a.vertical();
        shell.setClipChildren(false);
        shell.setClipToPadding(false);
        shell.setPadding(a.dp(56), a.dp(32), a.dp(56), a.dp(24));
        a.root.addView(shell, new FrameLayout.LayoutParams(-1, -1));

        // Fixed Top Apple tvOS Header Row (Title + Live Clock)
        LinearLayout headerBar = a.row();
        headerBar.setGravity(Gravity.CENTER_VERTICAL);
        TextView heading = a.text("设置", 32, TvV17Theme.TEXT);
        heading.setTypeface(null, Typeface.BOLD);
        headerBar.addView(heading, new LinearLayout.LayoutParams(0, -2, 1f));
        String clockText =
                new java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault())
                        .format(new java.util.Date());
        TextView clock = a.text(clockText, 16, 0xb8ebebf5);
        clock.setTypeface(null, Typeface.BOLD);
        headerBar.addView(clock);
        shell.addView(headerBar, new LinearLayout.LayoutParams(-1, -2));
        a.gap(shell, 26);

        LinearLayout columns = a.row();
        columns.setGravity(Gravity.TOP);
        columns.setClipChildren(false);
        columns.setClipToPadding(false);
        shell.addView(columns, new LinearLayout.LayoutParams(-1, 0, 1f));

        // Left Fixed Primary Sidebar: each category switches atomically to an Apple tvOS white
        // pill with instant zero-lag focus handoff (no sliding box, no two-stage dimming).
        LinearLayout navigation = a.vertical();
        navigation.setClipChildren(false);
        navigation.setClipToPadding(false);
        navigation.setPadding(a.dp(2), a.dp(4), a.dp(2), a.dp(12));
        LinearLayout.LayoutParams navSize = new LinearLayout.LayoutParams(a.dp(266), -1);
        navSize.rightMargin = a.dp(52);
        columns.addView(navigation, navSize);

        // Right Host FrameLayout holds one independent HWUI-cached TvScrollView per category so
        // switching primary categories flips RenderNode alpha in <0.5ms with zero View.GONE
        // DisplayList destruction or layout thrashing.
        tvRightHost = new FrameLayout(a);
        tvRightHost.setClipChildren(false);
        tvRightHost.setClipToPadding(false);
        columns.addView(tvRightHost, new LinearLayout.LayoutParams(0, -1, 1f));

        tvCategory(navigation, TV_CAT_APPEARANCE, "外观与壁纸", "settings-appearance");
        tvCategory(navigation, TV_CAT_PLAYBACK, "播放与字幕", "settings-playback");
        tvCategory(navigation, TV_CAT_CONTENT, "片源与直播", "settings-content");
        tvCategory(navigation, TV_CAT_BACKUP, "数据与备份", "settings-backup-page");
        tvCategory(navigation, TV_CAT_UPDATES, "软件更新", "settings-updates");

        View navSpacer = new View(a);
        navigation.addView(navSpacer, new LinearLayout.LayoutParams(1, 0, 1f));

        LinearLayout brandFoot = a.vertical();
        brandFoot.setPadding(a.dp(16), a.dp(14), a.dp(16), a.dp(14));
        brandFoot.setBackground(TvV17Surface.rounded(0x4d141822, a.dp(16), 0x1cffffff, a.dp(1)));
        TextView brandTitle =
                a.text("Marco Movie  " + UpdateManager.installedVersion(a), 13, 0xd8f5f5f7);
        brandTitle.setTypeface(null, Typeface.BOLD);
        brandFoot.addView(brandTitle);
        TextView hint = a.text("↑↓ 即时切换 · → 进入右侧 · 返回退出", 11.5f, 0x99ebebf5);
        hint.setPadding(0, a.dp(5), 0, 0);
        brandFoot.addView(hint);
        navigation.addView(brandFoot, new LinearLayout.LayoutParams(-1, -2));

        TvScrollView initialScroll = createTvRightScroll();
        LinearLayout initialPane = createTvCategoryPane();
        initialScroll.addView(initialPane, new ScrollView.LayoutParams(-1, -2));
        tvRightHost.addView(initialScroll, new FrameLayout.LayoutParams(-1, -1));
        tvActiveScroll = initialScroll;
        a.scroll = initialScroll;
        a.body = initialPane;
        boolean isDecoders = "解码组件".equals(title);
        if (!isDecoders && tvSelectedCategory >= 0 && tvSelectedCategory < TV_CAT_COUNT) {
            tvCategoryScrolls[tvSelectedCategory] = initialScroll;
            tvCategoryPanes[tvSelectedCategory] = initialPane;
        }
        renderTvRightHeader(initialPane, title, note);
        if (!isDecoders) {
            scheduleTvCategoryPrewarm();
        }
        if (tvActiveCategoryButton != null) {
            a.tvInitialFocus = tvActiveCategoryButton;
        }
        if (tvActiveCategoryButton != null
                && (a.current == null || a.current.focus == null || a.current.focus.isEmpty())) {
            final View initialCat = tvActiveCategoryButton;
            a.ui.post(
                    () -> {
                        if (initialCat.isAttachedToWindow()
                                && (a.current == null
                                        || a.current.focus == null
                                        || a.current.focus.isEmpty())) {
                            initialCat.requestFocus();
                        }
                    });
        }
    }

    private TvScrollView createTvRightScroll() {
        TvScrollView scroller = new TvScrollView(a);
        scroller.readingMode = true;
        scroller.setFocusFrameEnabled(false);
        scroller.setFillViewport(true);
        scroller.setVerticalScrollBarEnabled(false);
        scroller.setClipChildren(false);
        scroller.setClipToPadding(false);
        return scroller;
    }

    private LinearLayout createTvCategoryPane() {
        LinearLayout pane = a.vertical();
        pane.setClipChildren(false);
        pane.setClipToPadding(false);
        pane.setPadding(a.dp(8), a.dp(4), a.dp(16), a.dp(56));
        return pane;
    }

    private void scheduleTvCategoryPrewarm() {
        if (tvRightHost == null || a.isFinishing()) return;
        final int ticket = a.generation;
        final FrameLayout host = tvRightHost;
        host.post(
                () -> {
                    if (a.isFinishing() || a.generation != ticket || !host.isAttachedToWindow()) {
                        return;
                    }
                    final int[] nextCat = new int[] {0};
                    android.os.Looper.myQueue()
                            .addIdleHandler(
                                    () -> {
                                        if (a.isFinishing()
                                                || a.generation != ticket
                                                || !host.isAttachedToWindow()) {
                                            return false;
                                        }
                                        while (nextCat[0] < TV_CAT_COUNT
                                                && tvCategoryScrolls[nextCat[0]] != null) {
                                            nextCat[0]++;
                                        }
                                        if (nextCat[0] >= TV_CAT_COUNT) return false;
                                        int target = nextCat[0]++;
                                        ensureTvCategoryScroll(target, false);
                                        return nextCat[0] < TV_CAT_COUNT;
                                    });
                });
    }

    private TvScrollView ensureTvCategoryScroll(final int catIndex, boolean active) {
        TvScrollView existing = tvCategoryScrolls[catIndex];
        if (existing != null) return existing;
        LinearLayout prevBody = a.body;
        int prevBuilding = tvBuildingCategory;
        tvBuildingCategory = catIndex;
        TvScrollView scroller = createTvRightScroll();
        LinearLayout pane = createTvCategoryPane();
        scroller.addView(pane, new ScrollView.LayoutParams(-1, -2));
        tvCategoryScrolls[catIndex] = scroller;
        tvCategoryPanes[catIndex] = pane;
        tvCategoryFirstControls[catIndex] = null;
        a.body = pane;
        try {
            switch (catIndex) {
                case TV_CAT_PLAYBACK:
                    renderTvRightHeader(pane, "播放与字幕", "作为之后播放的默认设置；播放界面中仍可随时调整。");
                    playbackRows();
                    break;
                case TV_CAT_CONTENT:
                    renderTvRightHeader(pane, "片源与直播", "搜索默认识别首拼和全拼，并检索配置中全部可搜索来源。");
                    contentRows();
                    break;
                case TV_CAT_BACKUP:
                    renderTvRightHeader(pane, "数据与备份", "管理同步、备份和本机记录。");
                    backupRows();
                    break;
                case TV_CAT_UPDATES:
                    renderTvRightHeader(pane, "软件更新", "镜像站优先加速检查与下载，安装前自动校验 SHA-256 与应用签名。");
                    tvUpdateInlineRows();
                    break;
                default:
                    renderTvRightHeader(pane, "外观与壁纸", "界面按屏幕分辨率自动适配，支持首页封面自适应柔光、自定义柔光渐变与扫码上传壁纸。");
                    appearanceRows();
                    break;
            }
        } finally {
            tvBuildingCategory = prevBuilding;
            a.body = active ? pane : prevBody;
        }
        if (active) {
            scroller.setFocusable(true);
            scroller.setAlpha(1f);
            scroller.setDescendantFocusability(android.view.ViewGroup.FOCUS_AFTER_DESCENDANTS);
            tvRightHost.addView(scroller, new FrameLayout.LayoutParams(-1, -1));
        } else {
            // Prime HWUI RenderNode DisplayLists at an imperceptible alpha (0.002 < 1/255) for one
            // idle frame, then park at alpha=0 so the very first category visit draws in <1ms.
            scroller.setFocusable(false);
            scroller.setDescendantFocusability(android.view.ViewGroup.FOCUS_BLOCK_DESCENDANTS);
            scroller.setAlpha(0.002f);
            tvRightHost.addView(scroller, 0, new FrameLayout.LayoutParams(-1, -1));
            scroller.postOnAnimation(
                    () -> {
                        if (scroller.isAttachedToWindow() && tvSelectedCategory != catIndex) {
                            scroller.setAlpha(0f);
                        }
                    });
        }
        return scroller;
    }

    private void renderTvRightHeader(LinearLayout content, String title, String note) {
        TextView section = a.text(title, 26, TvV17Theme.TEXT);
        section.setTypeface(null, Typeface.BOLD);
        content.addView(section);
        if (note != null && !note.isEmpty()) {
            TextView noteView = a.text(note, 13.5f, 0xa8ebebf5);
            noteView.setLineSpacing(a.dp(2), 1.12f);
            noteView.setPadding(0, a.dp(8), 0, a.dp(22));
            content.addView(noteView);
        } else {
            a.gap(content, 20);
        }
    }

    private void updateTvCategoryRenderBinding(int catIndex) {
        if (a.current == null) return;
        switch (catIndex) {
            case TV_CAT_PLAYBACK:
                a.current.render = () -> new SettingsScreen(a).playback();
                break;
            case TV_CAT_CONTENT:
                a.current.render = () -> new SettingsScreen(a).content();
                break;
            case TV_CAT_BACKUP:
                a.current.render = () -> new SettingsScreen(a).backup();
                break;
            case TV_CAT_UPDATES:
                a.current.render = () -> new SettingsScreen(a).updatesCategory();
                break;
            default:
                a.current.render = () -> new SettingsScreen(a).appearance();
                break;
        }
    }

    private void switchTvCategoryInPlace(int catIndex, boolean moveFocusToRight) {
        if (tvRightHost == null || a.isFinishing()) return;
        if (catIndex < 0 || catIndex >= TV_CAT_COUNT) catIndex = TV_CAT_APPEARANCE;
        TvScrollView targetScroll = ensureTvCategoryScroll(catIndex, true);
        boolean changed = (catIndex != tvSelectedCategory) || tvActiveScroll != targetScroll;
        if (changed) {
            if (tvActiveScroll != null && tvActiveScroll != targetScroll) {
                tvActiveScroll.cancelMotion();
                tvActiveScroll.setAlpha(0f);
                tvActiveScroll.setFocusable(false);
                tvActiveScroll.setDescendantFocusability(
                        android.view.ViewGroup.FOCUS_BLOCK_DESCENDANTS);
            }
            tvSelectedCategory = catIndex;
            tvActiveCategoryButton = tvCategoryViews.get(catIndex);
            tvActiveScroll = targetScroll;
            a.scroll = targetScroll;
            a.body = tvCategoryPanes[catIndex];
            if (targetScroll.getScrollY() != 0) targetScroll.scrollTo(0, 0);
            targetScroll.setFocusable(true);
            targetScroll.setDescendantFocusability(android.view.ViewGroup.FOCUS_AFTER_DESCENDANTS);
            targetScroll.setAlpha(1f);

            tvFirstRightControl = tvCategoryFirstControls[catIndex];
            if (tvActiveCategoryButton != null && tvFirstRightControl != null) {
                tvActiveCategoryButton.setNextFocusRightId(tvFirstRightControl.getId());
            }
            for (Runnable r : tvCategoryRefreshers) r.run();
            updateTvCategoryRenderBinding(catIndex);
        }
        if (moveFocusToRight && tvFirstRightControl != null) {
            tvFirstRightControl.requestFocus();
        }
    }

    private void registerTvRightControl(View control) {
        if (!a.isTvDevice() || control == null) return;
        if (control.getId() == View.NO_ID) control.setId(View.generateViewId());
        int targetCat = tvBuildingCategory >= 0 ? tvBuildingCategory : tvSelectedCategory;
        View catBtn =
                (targetCat >= 0 && targetCat < TV_CAT_COUNT)
                        ? tvCategoryViews.get(targetCat)
                        : tvActiveCategoryButton;
        if (catBtn != null) {
            control.setNextFocusLeftId(catBtn.getId());
        }
        if (targetCat >= 0 && targetCat < TV_CAT_COUNT) {
            if (tvCategoryFirstControls[targetCat] == null) {
                tvCategoryFirstControls[targetCat] = control;
                if (catBtn != null) catBtn.setNextFocusRightId(control.getId());
                if (targetCat == tvSelectedCategory) {
                    tvFirstRightControl = control;
                }
            }
        } else if (tvFirstRightControl == null) {
            tvFirstRightControl = control;
            if (catBtn != null) catBtn.setNextFocusRightId(control.getId());
        }
    }

    void tvCategory(LinearLayout parent, final int catIndex, String title, String tag) {
        final LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(a.dp(14), a.dp(11), a.dp(16), a.dp(11));
        row.setTag(tag);
        row.setId(View.generateViewId());
        row.setFocusable(true);
        row.setFocusableInTouchMode(true);
        row.setClickable(true);
        a.pressFeedback(row);

        MobileShell.SettingIconView icon =
                new MobileShell.SettingIconView(
                        a, MobileShell.SettingIconView.kindForSetting(tag, title));
        LinearLayout.LayoutParams iconLp = new LinearLayout.LayoutParams(a.dp(30), a.dp(30));
        iconLp.rightMargin = a.dp(12);
        row.addView(icon, iconLp);

        final TextView label = a.text(title, 15.5f, MainActivity.WHITE);
        label.setTypeface(null, Typeface.BOLD);
        label.setSingleLine(true);
        row.addView(label, new LinearLayout.LayoutParams(0, -2, 1f));

        final boolean reducedTrans = a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
        final android.graphics.drawable.Drawable focusedBg =
                TvV17Surface.rounded(0xfff5f5f7, a.dp(14), 0xffffffff, a.dp(1));
        final android.graphics.drawable.Drawable activeBg =
                TvV17Surface.rounded(0x36ffffff, a.dp(14), 0x55ffffff, a.dp(1));
        final android.graphics.drawable.Drawable idleBg =
                TvV17Surface.rounded(
                        reducedTrans ? 0xee1c212b : 0x661a1f29, a.dp(14), 0x1affffff, a.dp(1));
        final Runnable applyVisual =
                () -> {
                    boolean active = (catIndex == tvSelectedCategory);
                    boolean focused = row.hasFocus();
                    if (focused) {
                        if (row.getBackground() != focusedBg) row.setBackground(focusedBg);
                        if (label.getCurrentTextColor() != 0xff101013) {
                            label.setTextColor(0xff101013);
                        }
                    } else {
                        android.graphics.drawable.Drawable targetBg = active ? activeBg : idleBg;
                        if (row.getBackground() != targetBg) row.setBackground(targetBg);
                        int textColor = active ? MainActivity.WHITE : 0xc8e4ebf5;
                        if (label.getCurrentTextColor() != textColor) {
                            label.setTextColor(textColor);
                        }
                    }
                };
        tvCategoryRefreshers.add(applyVisual);
        tvCategoryViews.put(catIndex, row);
        applyVisual.run();
        row.setOnFocusChangeListener(
                (v, focused) -> {
                    row.animate().cancel();
                    if (focused) {
                        if (catIndex != tvSelectedCategory) {
                            switchTvCategoryInPlace(catIndex, false);
                        }
                        applyVisual.run();
                        float scale = a.reduced ? 1f : 1.028f;
                        if (a.reduced) {
                            row.setScaleX(1f);
                            row.setScaleY(1f);
                        } else {
                            row.animate()
                                    .scaleX(scale)
                                    .scaleY(scale)
                                    .setDuration(70)
                                    .setInterpolator(tvDecel())
                                    .start();
                        }
                    } else {
                        // Snap scale immediately on blur so the previous row never lingers halfway
                        // down while the newly focused row is already bright white.
                        row.setScaleX(1f);
                        row.setScaleY(1f);
                        applyVisual.run();
                    }
                });
        row.setOnClickListener(v -> switchTvCategoryInPlace(catIndex, true));
        LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(-1, a.dp(58));
        size.bottomMargin = a.dp(12);
        parent.addView(row, size);
        if (catIndex == tvSelectedCategory) tvActiveCategoryButton = row;
    }

    void updatesCategory() {
        page("软件更新", "镜像站优先加速检查与下载，安装前自动校验 SHA-256 与应用签名。");
        tvUpdateInlineRows();
    }

    private void tvUpdateInlineRows() {
        final UpdateManager updates = UpdateManager.get(a);
        String installed = UpdateManager.installedVersion(a);
        UpdateManager.Release rel = updates.available;
        String statusDetail =
                updates.busy
                        ? (updates.message
                                + (updates.percent >= 0 ? " · " + updates.percent + "%" : ""))
                        : (rel != null
                                ? ("发现新版 " + rel.version + " · " + updates.message)
                                : ("当前版本 " + installed + " · " + updates.message));
        link(
                rel != null
                        ? (updates.ready() ? "立即安装新版 " + rel.version : "下载并更新至 " + rel.version)
                        : "检查软件更新",
                statusDetail,
                "settings-update-action",
                () -> {
                    if (updates.busy) {
                        updates.cancel();
                        a.refresh();
                    } else if (updates.ready() || rel != null) {
                        open(() -> new UpdateScreen(a).show());
                    } else {
                        updates.check(true);
                        a.toast("正在检查新版…");
                        open(() -> new UpdateScreen(a).show());
                    }
                });
        link(
                "自动更新策略",
                UpdateScreen.modeName(updates.mode()),
                "settings-update-mode",
                () -> {
                    String[] modes = {"notify", "download", "off"};
                    new AppDialog.Builder(a)
                            .setTitle("更新方式")
                            .setMessage("自动检查至少间隔六小时，仅在应用首页运行时发起。播放过程中不弹出更新窗口；安装始终由你确认。")
                            .setSingleChoiceItems(
                                    new String[] {"自动检查并提醒", "自动下载后提醒", "仅手动检查"},
                                    java.util.Arrays.asList(modes).indexOf(updates.mode()),
                                    (d, n) -> {
                                        updates.setMode(modes[n]);
                                        a.refresh();
                                    })
                            .setNegativeButton("返回", null)
                            .show();
                });
        link(
                "打开完整软件更新中心",
                "查看版本更新说明、下载进度与安装包校验",
                "settings-update-full",
                () -> open(() -> new UpdateScreen(a).show()));
    }

    void link(String title, String detail, String key, Runnable action) {
        boolean tv = a.isTvDevice();
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(
                a.dp(tv ? 22 : 18), a.dp(tv ? 18 : 14), a.dp(tv ? 22 : 18), a.dp(tv ? 18 : 14));
        MobileShell.SettingIconView icon =
                new MobileShell.SettingIconView(
                        a, MobileShell.SettingIconView.kindForSetting(key, title));
        LinearLayout.LayoutParams iconLp =
                new LinearLayout.LayoutParams(a.dp(tv ? 36 : 38), a.dp(tv ? 36 : 38));
        iconLp.rightMargin = a.dp(tv ? 16 : 14);
        row.addView(icon, iconLp);

        boolean inlineValue = tv && detail != null && !detail.isEmpty() && detail.length() <= 20;
        LinearLayout copy = a.vertical();
        final TextView titleView = a.text(title, tv ? 16 : 17, MainActivity.WHITE);
        titleView.setTypeface(null, Typeface.BOLD);
        copy.addView(titleView);
        final TextView caption;
        if (!inlineValue && detail != null && !detail.isEmpty()) {
            caption = a.text(detail, 12.5f, 0xa8ebebf5);
            caption.setPadding(0, a.dp(3), 0, 0);
            copy.addView(caption);
        } else {
            caption = null;
        }
        row.addView(copy, new LinearLayout.LayoutParams(0, -2, 1));

        final TextView rightValue;
        if (inlineValue) {
            rightValue = a.text(detail, 14, 0xb8ebebf5);
            rightValue.setSingleLine(true);
            rightValue.setPadding(a.dp(10), 0, a.dp(8), 0);
            row.addView(rightValue);
        } else {
            rightValue = null;
        }
        final TextView chevron = a.text("›", 22, 0x88ebebf5);
        row.addView(chevron);
        row.setTag(key);
        row.setId(View.generateViewId());
        row.setFocusable(tv);
        row.setFocusableInTouchMode(tv);
        row.setClickable(true);
        final int surface =
                tv && a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false)
                        ? 0xee1c212b
                        : 0xbf1a1f29;
        final android.graphics.drawable.Drawable restingBg =
                tv
                        ? TvV17Surface.rounded(surface, a.dp(14), 0x22ffffff, a.dp(1))
                        : a.bg(0xff222226, 14);
        final android.graphics.drawable.Drawable focusedBg =
                tv ? TvV17Surface.rounded(0xfff5f5f7, a.dp(14), 0xffffffff, a.dp(1)) : null;
        row.setBackground(restingBg);
        row.setOnFocusChangeListener(
                (v, f) -> {
                    if (!tv) {
                        FocusMotion.style(
                                a,
                                row,
                                f,
                                0xff222226,
                                0xff37373e,
                                14,
                                MainActivity.WHITE,
                                MainActivity.WHITE,
                                true,
                                1.008f);
                        return;
                    }
                    row.animate().cancel();
                    if (f) {
                        if (row.getBackground() != focusedBg) row.setBackground(focusedBg);
                        titleView.setTextColor(0xff101013);
                        if (caption != null) caption.setTextColor(0xff48484a);
                        if (rightValue != null) rightValue.setTextColor(0xff3a3a3c);
                        chevron.setTextColor(0xff636366);
                        float scale = a.reduced ? 1f : 1.014f;
                        if (a.reduced) {
                            row.setScaleX(1f);
                            row.setScaleY(1f);
                        } else {
                            row.animate()
                                    .scaleX(scale)
                                    .scaleY(scale)
                                    .setDuration(70)
                                    .setInterpolator(tvDecel())
                                    .start();
                        }
                    } else {
                        if (row.getBackground() != restingBg) row.setBackground(restingBg);
                        titleView.setTextColor(MainActivity.WHITE);
                        if (caption != null) caption.setTextColor(0xa8ebebf5);
                        if (rightValue != null) rightValue.setTextColor(0xb8ebebf5);
                        chevron.setTextColor(0x88ebebf5);
                        row.setScaleX(1f);
                        row.setScaleY(1f);
                    }
                });
        if (tv) {
            a.pressFeedback(row);
            registerTvRightControl(row);
        } else {
            MobileShell.bindCardTouchFeedback(a, row, a.bg(0xff222226, 14), a.bg(0xff303038, 14));
        }
        row.setOnClickListener(v -> action.run());
        LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(-1, -2);
        size.bottomMargin = a.dp(14);
        a.body.addView(row, size);
    }

    void open(Runnable page) {
        a.open(new MainActivity.Screen(page), true);
    }

    void show() {
        if (a.isTvDevice()) {
            appearance();
            return;
        }
        page("设置", "");
        link("首页与壁纸", "", "settings-appearance", () -> open(this::appearance));
        link("播放与字幕", "", "settings-playback", () -> open(this::playback));
        link("搜索与数据", "", "settings-data", () -> open(this::data));
        link("软件更新", "", "settings-updates", () -> open(() -> new UpdateScreen(a).show()));
    }

    void decoders() {
        page("解码组件", "组件随应用安装，无需另外下载解码包。");
        a.paragraph(DecoderSupport.description());
    }

    void openConfigSiteHome(Cms.Site targetSite) {
        a.prefs.edit().putString(Prefs.SELECTED_SITE, targetSite.key).apply();
        MobileShell.activeTab = 0;
        a.back.clear();
        a.open(new MainActivity.Screen(a::home), false);
    }

    interface AccountChoice {
        void accept(int index);
    }

    void showAccountActionPicker(
            String title, String subtitle, String[] labels, AccountChoice handleChoice) {
        if (!a.isTvDevice()) {
            MobileShell.showDrawerPicker(a, title, subtitle, labels, -1, handleChoice::accept);
        } else {
            new AppDialog.Builder(a)
                    .setTitle(title)
                    .setItems(labels, (d, which) -> handleChoice.accept(which))
                    .setNegativeButton("关闭", null)
                    .show();
        }
    }

    static Cms.Video findSortCard(java.util.List<Cms.Video> videos) {
        if (videos == null) return null;
        for (Cms.Video v : videos) {
            if (v == null) continue;
            String id = v.id == null ? "" : v.id.toLowerCase(java.util.Locale.ROOT);
            String act = v.action == null ? "" : v.action.toLowerCase(java.util.Locale.ROOT);
            String title = v.title == null ? "" : v.title;
            if (id.contains("pan_order")
                    || id.contains("panorder")
                    || id.contains("panpaixu")
                    || act.contains("pan_order")
                    || act.contains("panorder")
                    || act.contains("panpaixu")
                    || title.contains("优先顺序")
                    || title.contains("搜索顺序")
                    || title.contains("网盘排序")
                    || title.contains("网盘顺序")
                    || title.contains("盘序")) {
                return v;
            }
        }
        return null;
    }

    static Cms.Video findDirectDriveCard(java.util.List<Cms.Video> videos, String driveKey) {
        if (videos == null || driveKey == null || driveKey.trim().isEmpty()) return null;
        String target = driveKey.trim().toLowerCase(java.util.Locale.ROOT);
        Cms.Video fallback = null;
        for (Cms.Video v : videos) {
            if (v == null) continue;
            String title = v.title == null ? "" : v.title.trim();
            String id = v.id == null ? "" : v.id.toLowerCase(java.util.Locale.ROOT);
            String act = v.action == null ? "" : v.action.toLowerCase(java.util.Locale.ROOT);
            if (title.contains("清除") || title.contains("重置") || id.contains("clear")) {
                continue;
            }
            String detected = PluginDialogStyler.detectDriveKeyFromLabel(title);
            if (detected == null) detected = PluginDialogStyler.detectDriveKeyFromLabel(id);
            if (detected == null) detected = PluginDialogStyler.detectDriveKeyFromLabel(act);
            if (!target.equals(detected)) continue;
            if (title.contains("扫码")
                    || title.contains("二维码")
                    || title.contains("登录")
                    || title.contains("登入")
                    || id.contains("qr")
                    || id.contains("scan")
                    || id.contains("login")) {
                return v;
            }
            if (fallback == null) fallback = v;
        }
        return fallback;
    }

    void openDirectDriveConfigAction(
            Cms.Site targetSite, String driveKey, boolean toggleEnableOnly) {
        final int ticket = a.generation;
        a.worker.execute(
                () -> {
                    try {
                        CspEngine.syncAllPluginActivities(a);
                        SourceEngine eng = a.engine(targetSite);
                        String homeRaw = eng.home();
                        java.util.List<Cms.Category> cats = Cms.categories(homeRaw);
                        Cms.Listing homeList = null;
                        try {
                            homeList = Cms.listing(homeRaw);
                        } catch (Throwable ignored) {
                        }
                        Cms.Video matched =
                                findDirectDriveCard(
                                        homeList != null ? homeList.videos : null, driveKey);
                        if (matched == null && cats != null) {
                            for (Cms.Category c : cats) {
                                String cname = c.name == null ? "" : c.name;
                                String cid =
                                        c.id == null ? "" : c.id.toLowerCase(java.util.Locale.ROOT);
                                if (driveKey.equals(
                                                PluginDialogStyler.detectDriveKeyFromLabel(cname))
                                        || cname.contains("网盘")
                                        || cname.contains("云盘")
                                        || cname.contains("扫码")
                                        || cname.contains("登录")
                                        || cid.contains("pan")
                                        || cid.contains("config")) {
                                    try {
                                        Cms.Listing cl = Cms.listing(eng.category(c.id, 1));
                                        matched = findDirectDriveCard(cl.videos, driveKey);
                                        if (matched != null) break;
                                    } catch (Throwable ignored) {
                                    }
                                }
                            }
                        }
                        if (matched != null) {
                            final Cms.Video card = matched;
                            a.ui.post(
                                    () -> {
                                        if (a.isFinishing() || ticket != a.generation) return;
                                        PluginDialogStyler.watch(a);
                                        a.openListing(targetSite, card);
                                    });
                            return;
                        }
                        String targetApi =
                                targetSite.api == null
                                        ? ""
                                        : targetSite.api.toLowerCase(java.util.Locale.ROOT);
                        String targetKey =
                                targetSite.key == null
                                        ? ""
                                        : targetSite.key.toLowerCase(java.util.Locale.ROOT);
                        final boolean isMyDriveSpider =
                                targetApi.contains("mydrive") || targetKey.contains("mydrive");
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing() || ticket != a.generation) return;
                                    if (isMyDriveSpider) {
                                        PluginDialogStyler.armDirectDriveForward(
                                                a, driveKey, toggleEnableOnly);
                                        a.sourceAction(targetSite, "LoginShow");
                                    } else {
                                        PluginDialogStyler.clearDirectDriveForward();
                                        openDynamicConfigSiteAction(targetSite, "LoginShow");
                                    }
                                });
                    } catch (Throwable error) {
                        String targetApi =
                                targetSite.api == null
                                        ? ""
                                        : targetSite.api.toLowerCase(java.util.Locale.ROOT);
                        String targetKey =
                                targetSite.key == null
                                        ? ""
                                        : targetSite.key.toLowerCase(java.util.Locale.ROOT);
                        final boolean isMyDriveSpider =
                                targetApi.contains("mydrive") || targetKey.contains("mydrive");
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing() || ticket != a.generation) return;
                                    if (isMyDriveSpider) {
                                        PluginDialogStyler.armDirectDriveForward(
                                                a, driveKey, toggleEnableOnly);
                                        a.sourceAction(targetSite, "LoginShow");
                                    } else {
                                        PluginDialogStyler.clearDirectDriveForward();
                                        openConfigSiteHome(targetSite);
                                    }
                                });
                    }
                });
    }

    void showDynamicVideoPicker(
            Cms.Site targetSite, String title, java.util.List<Cms.Video> videos) {
        if (videos == null || videos.isEmpty()) {
            openConfigSiteHome(targetSite);
            return;
        }
        String[] labels = new String[videos.size() + 1];
        for (int i = 0; i < videos.size(); i++) {
            Cms.Video v = videos.get(i);
            String name = v.title == null ? "" : v.title.trim();
            String rem = v.remarks == null ? "" : v.remarks.trim();
            if (!rem.isEmpty() && !rem.equals(name)) {
                labels[i] = name + " · " + rem;
            } else {
                labels[i] = name;
            }
        }
        labels[videos.size()] = "打开完整配置中心";
        showAccountActionPicker(
                title,
                "选择需要执行的网盘配置操作",
                labels,
                idx -> {
                    if (idx < 0 || idx > videos.size()) return;
                    if (idx == videos.size()) {
                        openConfigSiteHome(targetSite);
                    } else {
                        a.openListing(targetSite, videos.get(idx));
                    }
                });
    }

    void openDynamicConfigCategory(Cms.Site targetSite, Cms.Category cat) {
        final int ticket = a.generation;
        a.worker.execute(
                () -> {
                    try {
                        CspEngine.syncAllPluginActivities(a);
                        SourceEngine eng = a.engine(targetSite);
                        Cms.Listing list = Cms.listing(eng.category(cat.id, 1));
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing() || ticket != a.generation) return;
                                    showDynamicVideoPicker(targetSite, cat.name, list.videos);
                                });
                    } catch (Throwable error) {
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing() || ticket != a.generation) return;
                                    openConfigSiteHome(targetSite);
                                });
                    }
                });
    }

    void openDynamicConfigSiteAction(Cms.Site targetSite, String action) {
        final int ticket = a.generation;
        final boolean wantSort = "panSortShow".equals(action) || "panSourceSortShow".equals(action);
        a.worker.execute(
                () -> {
                    try {
                        CspEngine.syncAllPluginActivities(a);
                        SourceEngine eng = a.engine(targetSite);
                        String homeRaw = eng.home();
                        java.util.List<Cms.Category> cats = Cms.categories(homeRaw);
                        Cms.Listing homeList = null;
                        try {
                            homeList = Cms.listing(homeRaw);
                        } catch (Throwable ignored) {
                        }
                        if (wantSort) {
                            Cms.Video sortCard =
                                    findSortCard(homeList != null ? homeList.videos : null);
                            if (sortCard == null && cats != null) {
                                for (Cms.Category c : cats) {
                                    String cid =
                                            c.id == null
                                                    ? ""
                                                    : c.id.toLowerCase(java.util.Locale.ROOT);
                                    String cname = c.name == null ? "" : c.name;
                                    if (cid.contains("pan")
                                            || cid.contains("config")
                                            || cname.contains("网盘")
                                            || cname.contains("配置")) {
                                        try {
                                            Cms.Listing cl = Cms.listing(eng.category(c.id, 1));
                                            sortCard = findSortCard(cl.videos);
                                            if (sortCard != null) break;
                                        } catch (Throwable ignored) {
                                        }
                                    }
                                }
                            }
                            if (sortCard != null) {
                                final Cms.Video found = sortCard;
                                a.ui.post(
                                        () -> {
                                            if (a.isFinishing() || ticket != a.generation) return;
                                            a.openListing(targetSite, found);
                                        });
                                return;
                            }
                        }
                        if (cats != null && !cats.isEmpty()) {
                            final java.util.List<Cms.Category> categoryList = cats;
                            a.ui.post(
                                    () -> {
                                        if (a.isFinishing() || ticket != a.generation) return;
                                        String[] labels = new String[categoryList.size() + 1];
                                        for (int i = 0; i < categoryList.size(); i++) {
                                            labels[i] = categoryList.get(i).name;
                                        }
                                        labels[categoryList.size()] = "打开完整配置中心";
                                        showAccountActionPicker(
                                                targetSite.name,
                                                "选择需要配置的网盘或功能分类",
                                                labels,
                                                idx -> {
                                                    if (idx < 0 || idx > categoryList.size())
                                                        return;
                                                    if (idx == categoryList.size()) {
                                                        openConfigSiteHome(targetSite);
                                                    } else {
                                                        openDynamicConfigCategory(
                                                                targetSite, categoryList.get(idx));
                                                    }
                                                });
                                    });
                            return;
                        }
                        if (homeList != null && !homeList.videos.isEmpty()) {
                            final java.util.List<Cms.Video> videos = homeList.videos;
                            a.ui.post(
                                    () -> {
                                        if (a.isFinishing() || ticket != a.generation) return;
                                        showDynamicVideoPicker(targetSite, targetSite.name, videos);
                                    });
                            return;
                        }
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing() || ticket != a.generation) return;
                                    openConfigSiteHome(targetSite);
                                });
                    } catch (Throwable error) {
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing() || ticket != a.generation) return;
                                    openConfigSiteHome(targetSite);
                                });
                    }
                });
    }

    void accountAction(String action) {
        accountAction(action, null);
    }

    void accountAction(String action, Cms.Site explicitConfigSite) {
        if (a.config != null) {
            Cms.Site fallback = explicitConfigSite;
            if (fallback == null) {
                fallback = AccountPanel.findConfigCenterSite(a);
            }
            if (fallback == null) {
                String currentKey = a.prefs.getString(Prefs.SELECTED_SITE, "");
                if (currentKey != null && !currentKey.isEmpty()) {
                    for (Cms.Site site : a.config.sites) {
                        if (currentKey.equals(site.key)
                                && SourceController.isDedicatedConfigSite(site)) {
                            fallback = site;
                            break;
                        }
                    }
                }
            }
            if (fallback == null) {
                for (Cms.Site site : a.config.sites) {
                    if (site.api != null
                            && site.api.toLowerCase(java.util.Locale.ROOT).contains("mydrive")) {
                        fallback = site;
                        break;
                    }
                    if (fallback == null && SourceController.isDedicatedConfigSite(site)) {
                        fallback = site;
                    }
                }
            }
            if (fallback == null) {
                for (Cms.Site site : a.config.sites) {
                    if (SourceController.isConfigOrNetdiskSite(site)) {
                        fallback = site;
                        break;
                    }
                }
            }
            if (fallback != null) {
                if (!a.available(fallback)) {
                    a.notice("请先在“搜索与数据”中启用来源扩展。");
                    return;
                }
                final Cms.Site targetSite = fallback;
                String api =
                        targetSite.api == null
                                ? ""
                                : targetSite.api.toLowerCase(java.util.Locale.ROOT);
                String key =
                        targetSite.key == null
                                ? ""
                                : targetSite.key.toLowerCase(java.util.Locale.ROOT);
                boolean isMyDrive = api.contains("mydrive") || key.contains("mydrive");
                if (isMyDrive) {
                    a.ensureStoragePermissionForNetdisk(() -> a.sourceAction(targetSite, action));
                    return;
                }
                boolean isPanConfig = api.contains("panconfig") || key.contains("panconfig");
                if (isPanConfig) {
                    if ("LoginShow".equals(action)) {
                        final String[] labels =
                                new String[] {
                                    "夸克网盘扫码登录",
                                    "UC网盘 Cookie 扫码登录",
                                    "UC网盘 TV Token 扫码登录",
                                    "百度网盘扫码登录",
                                    "115网盘扫码登录",
                                    "天翼网盘扫码登录",
                                    "天翼网盘账号密码登录",
                                    "移动云盘扫码登录",
                                    "光鸭网盘扫码登录",
                                    "迅雷云盘扫码登录",
                                    "哔哩哔哩扫码登录",
                                    "123网盘账号密码设置",
                                    "打开完整配置中心"
                                };
                        final String[] codes =
                                new String[] {
                                    "quark",
                                    "uccookie",
                                    "uctoken",
                                    "baidu",
                                    "pan115",
                                    "pan189",
                                    "pan189account",
                                    "pan139",
                                    "guangya",
                                    "thunder",
                                    "bili",
                                    "pan123manual",
                                    "__open_config__"
                                };
                        showAccountActionPicker(
                                "网盘扫码与账号登录",
                                "选择需要扫码或配置凭据的网盘服务",
                                labels,
                                idx -> {
                                    if (idx < 0 || idx >= codes.length) return;
                                    String code = codes[idx];
                                    if ("__open_config__".equals(code)) {
                                        openConfigSiteHome(targetSite);
                                    } else {
                                        a.sourceAction(targetSite, code);
                                    }
                                });
                        return;
                    }
                    if ("pushCkShow".equals(action)) {
                        a.sourceAction(targetSite, "web");
                        return;
                    }
                    if ("panSortShow".equals(action) || "panSourceSortShow".equals(action)) {
                        a.sourceAction(targetSite, "panorder");
                        return;
                    }
                }
                boolean isWexConfig =
                        api.contains("wexconfig")
                                || api.contains("wexokconfig")
                                || key.contains("wexconfig")
                                || key.contains("wexokconfig");
                if (isWexConfig) {
                    if ("panSortShow".equals(action) || "panSourceSortShow".equals(action)) {
                        a.sourceAction(targetSite, "panpaixu");
                        return;
                    }
                    final String[] labels =
                            new String[] {
                                "夸克网盘扫码 / Cookie 设置",
                                "UC网盘扫码 / Cookie 设置①",
                                "UC网盘 TV 扫码设置②",
                                "阿里云盘扫码 / Token 设置",
                                "百度网盘扫码登录",
                                "115网盘扫码 / Cookie 设置",
                                "天翼云盘账号登录",
                                "移动云盘 Cookie 设置",
                                "123云盘账号登录",
                                "迅雷云盘账号登录",
                                "哔哩哔哩扫码 / Cookie 设置",
                                "网盘启用开关设置",
                                "打开完整配置中心"
                            };
                    final String[] codes =
                            new String[] {
                                "quarkcookie",
                                "ucpancookie",
                                "uctvpancookie",
                                "aliyuntoken",
                                "baidupanlogin",
                                "115pancookie",
                                "tianyilogin",
                                "ydyuncookie",
                                "pan123login",
                                "panxunleiuser",
                                "bilicookie",
                                "pankaiguan",
                                "__open_config__"
                            };
                    showAccountActionPicker(
                            "网盘扫码与账号登录",
                            "选择需要扫码或配置凭据的网盘服务",
                            labels,
                            idx -> {
                                if (idx < 0 || idx >= codes.length) return;
                                String code = codes[idx];
                                if ("__open_config__".equals(code)) {
                                    openConfigSiteHome(targetSite);
                                } else {
                                    a.sourceAction(targetSite, code);
                                }
                            });
                    return;
                }
                openDynamicConfigSiteAction(targetSite, action);
                return;
            }
        }
        a.notice("当前配置没有提供网盘账号入口，请先导入支持网盘的配置源。");
    }

    void appearance() {
        page("外观与壁纸", "界面按屏幕分辨率自动适配，支持首页封面自适应柔光、自定义柔光渐变与扫码上传壁纸。");
        appearanceRows();
    }

    void appearanceRows() {
        link(
                "首页壁纸与柔光主题",
                HomeAmbient.activeBackgroundSummary(a),
                "settings-wallpaper",
                () -> open(this::wallpaper));
        if (a.isTvDevice()) {
            addTvBackgroundStudioInline(true);
        }
        link(
                "界面大小",
                TvLayoutPolicy.percent(a.prefs.getInt(Prefs.UI_SCALE_PERCENT, 100))
                        + "% · 按钮、文字与图标一起调整",
                "setting-ui_scale_percent",
                () -> {
                    String[] scaleLabels = new String[] {"标准 · 自动适配", "放大 · 110%", "更大 · 120%"};
                    int[] scaleValues = new int[] {100, 110, 120};
                    int curScale =
                            a.prefs.getInt(Prefs.UI_SCALE_PERCENT, 100) == 120
                                    ? 2
                                    : a.prefs.getInt(Prefs.UI_SCALE_PERCENT, 100) == 110 ? 1 : 0;
                    if (!a.isTvDevice()) {
                        MobileShell.showDrawerPicker(
                                a,
                                "界面大小",
                                "标准会自动适配屏幕分辨率；选择后界面重新载入",
                                scaleLabels,
                                curScale,
                                n -> {
                                    a.prefs
                                            .edit()
                                            .putInt(Prefs.UI_SCALE_PERCENT, scaleValues[n])
                                            .apply();
                                    a.recreate();
                                });
                        return;
                    }
                    new AppDialog.Builder(a)
                            .setTitle("界面大小")
                            .setMessage("标准会自动适配屏幕分辨率。观看距离较远时可放大；选择后界面重新载入。")
                            .setSingleChoiceItems(
                                    scaleLabels,
                                    curScale,
                                    (d, n) -> {
                                        a.prefs
                                                .edit()
                                                .putInt(Prefs.UI_SCALE_PERCENT, scaleValues[n])
                                                .apply();
                                        a.recreate();
                                    })
                            .setNegativeButton("返回", null)
                            .show();
                });
        if (a.isTvDevice()) {
            int currentDockStyle = a.useLeftDock() ? 1 : 0;
            String[] dockLabels = new String[] {"顶部沉浸式导航栏（推荐）", "左侧简洁导航栏"};
            link(
                    "首页导航栏位置",
                    dockLabels[currentDockStyle],
                    "setting-" + Prefs.TV_DOCK_POSITION,
                    () ->
                            new AppDialog.Builder(a)
                                    .setTitle("首页导航栏位置")
                                    .setMessage("顶部导航栏常显左上角品牌标识，向下滚动时自动缩小为渐变沉浸样式；也可切换为左侧可展开导航栏。")
                                    .setSingleChoiceItems(
                                            dockLabels,
                                            currentDockStyle,
                                            (d, which) -> {
                                                android.content.SharedPreferences.Editor ed =
                                                        a.prefs.edit();
                                                if (which == 0) {
                                                    ed.putInt(Prefs.TV_NAVIGATION_MODE, 0)
                                                            .putInt(Prefs.TV_DOCK_POSITION, 1);
                                                } else {
                                                    ed.putInt(Prefs.TV_NAVIGATION_MODE, 1);
                                                }
                                                ed.apply();
                                                a.refresh();
                                            })
                                    .setNegativeButton("返回", null)
                                    .show());
            link(
                    "自定义导航栏顺序与名称",
                    TvNavConfig.summaryLabel(a),
                    "setting-tv-nav-custom",
                    () -> TvNavCustomizeDialog.show(a, a::refresh));
        }
        ints(
                "导航栏字体与按钮大小",
                Prefs.NAV_SCALE_PERCENT,
                new String[] {"紧凑 · 85%", "标准 · 100%", "偏大 · 115%", "大号 · 130%", "特大 · 140%"},
                new int[] {85, 100, 115, 130, 140},
                100);
        ints(
                "每行海报",
                Prefs.HOME_COLUMNS,
                new String[] {"最多 5 张 · 舒展", "最多 6 张", "最多 7 张", "最多 8 张"},
                new int[] {5, 6, 7, 8},
                5);
        if (!a.isTvDevice()) {
            toggle("首页推荐卡片", Prefs.SHOW_HERO_BANNER, true, null);
            toggle("海报配色柔光", Prefs.HOME_AMBIENT, true, null);
        }
        toggle(
                "减少透明效果",
                Prefs.REDUCED_TRANSPARENCY,
                false,
                () -> com.pilipala.glass.GlassworkSurface.invalidateBackdrop(a.root));
        toggle("开屏动画", Prefs.STARTUP_ANIMATION, true, null);
        toggle(
                "减少动态效果",
                Prefs.REDUCED,
                false,
                () -> a.reduced = a.prefs.getBoolean(Prefs.REDUCED, false));
    }

    private void applyTvBackgroundMode(int mode) {
        int clamped = Prefs.clampBgMode(mode);
        android.content.SharedPreferences.Editor edit =
                a.prefs
                        .edit()
                        .putInt(Prefs.TV_BG_MODE, clamped)
                        .putBoolean(Prefs.WALLPAPER_ENABLED, clamped == Prefs.BG_MODE_WALLPAPER)
                        .putBoolean(
                                Prefs.HOME_AMBIENT,
                                clamped == Prefs.BG_MODE_ADAPTIVE
                                        || clamped == Prefs.BG_MODE_GRADIENT);
        edit.apply();
        a.refresh();
    }

    private Button makeStudioPill(String label, String tag, boolean active, Runnable onClick) {
        final Button b = a.button(label, tag, onClick);
        b.setSingleLine(true);
        b.setMinWidth(0);
        b.setMinimumWidth(0);
        b.setTextSize(13.5f);
        b.setTypeface(null, active ? Typeface.BOLD : Typeface.NORMAL);
        b.setMinHeight(a.dp(40));
        b.setMinimumHeight(a.dp(40));
        b.setPadding(a.dp(16), a.dp(8), a.dp(16), a.dp(8));
        final int restBg = active ? 0xff0a84ff : 0x70262c38;
        final int restStroke = active ? 0x9980c2ff : 0x26ffffff;
        final android.graphics.drawable.Drawable restingBg =
                TvV17Surface.rounded(restBg, a.dp(20), restStroke, a.dp(1));
        final android.graphics.drawable.Drawable focusedBg =
                TvV17Surface.rounded(0xfff5f5f7, a.dp(20), 0xffffffff, a.dp(1));
        b.setBackground(restingBg);
        b.setTextColor(MainActivity.WHITE);
        b.setOnFocusChangeListener(
                (v, focused) -> {
                    b.animate().cancel();
                    if (focused) {
                        if (b.getBackground() != focusedBg) b.setBackground(focusedBg);
                        b.setTextColor(0xff101013);
                        float scale = a.reduced ? 1f : 1.035f;
                        if (a.reduced) {
                            b.setScaleX(1f);
                            b.setScaleY(1f);
                        } else {
                            b.animate()
                                    .scaleX(scale)
                                    .scaleY(scale)
                                    .setDuration(70)
                                    .setInterpolator(tvDecel())
                                    .start();
                        }
                    } else {
                        if (b.getBackground() != restingBg) b.setBackground(restingBg);
                        b.setTextColor(MainActivity.WHITE);
                        b.setScaleX(1f);
                        b.setScaleY(1f);
                    }
                });
        return b;
    }

    private void addTvBackgroundStudioInline(boolean compact) {
        final int mode = HomeAmbient.effectiveBgMode(a);
        final int currentPreset = Prefs.clampGlowPreset(a.prefs.getInt(Prefs.TV_GLOW_PRESET, 0));
        final int currentStrength = a.prefs.getInt(Prefs.TV_AMBIENT_PERCENT, 75);

        // Card 1: Background Mode Selector + Strength Controls
        LinearLayout studioCard = a.vertical();
        studioCard.setClipChildren(false);
        studioCard.setClipToPadding(false);
        studioCard.setPadding(a.dp(18), a.dp(16), a.dp(18), a.dp(16));
        studioCard.setBackground(TvV17Surface.rounded(0x991a1f29, a.dp(18), 0x24ffffff, a.dp(1)));

        TextView modeHeader = a.text("背景渲染模式", 15, MainActivity.WHITE);
        modeHeader.setTypeface(null, Typeface.BOLD);
        studioCard.addView(modeHeader);
        TextView modeSub = a.text("选择封面自适应柔光、自定义柔光渐变或手机扫码上传壁纸，切换即时生效", 12, 0xa6ebebf5);
        modeSub.setPadding(0, a.dp(4), 0, a.dp(12));
        studioCard.addView(modeSub);

        LinearLayout modeRow = a.row();
        modeRow.setClipChildren(false);
        modeRow.setClipToPadding(false);
        String[] modeLabels = {"封面自适应柔光", "自定义柔光渐变", "图片壁纸", "纯深色"};
        int[] modeValues = {
            Prefs.BG_MODE_ADAPTIVE,
            Prefs.BG_MODE_GRADIENT,
            Prefs.BG_MODE_WALLPAPER,
            Prefs.BG_MODE_DARK
        };
        for (int i = 0; i < modeLabels.length; i++) {
            final int targetMode = modeValues[i];
            Button pill =
                    makeStudioPill(
                            modeLabels[i],
                            "tv-bg-mode:" + targetMode,
                            mode == targetMode,
                            () -> {
                                if (targetMode == Prefs.BG_MODE_WALLPAPER
                                        && !new File(a.getFilesDir(), "wallpaper.jpg").exists()) {
                                    new WallpaperUploadDialog(a, a::refresh).show();
                                    return;
                                }
                                applyTvBackgroundMode(targetMode);
                            });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, a.dp(40));
            if (i > 0) lp.leftMargin = a.dp(10);
            modeRow.addView(pill, lp);
            if (i == 0) registerTvRightControl(pill);
        }
        studioCard.addView(modeRow, new LinearLayout.LayoutParams(-1, -2));

        // Strength pills when glow is active
        if (mode == Prefs.BG_MODE_ADAPTIVE || mode == Prefs.BG_MODE_GRADIENT) {
            a.gap(studioCard, 14);
            LinearLayout strengthRow = a.row();
            strengthRow.setClipChildren(false);
            strengthRow.setClipToPadding(false);
            TextView sLabel = a.text("柔光浓度", 13.5f, 0xc8ebebf5);
            LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(-2, -2);
            slp.rightMargin = a.dp(14);
            strengthRow.addView(sLabel, slp);
            String[] sLabels = {"柔和微光", "标准柔光", "浓郁流光"};
            int[] sVals = {35, 75, 100};
            int activeIdx = currentStrength <= 50 ? 0 : (currentStrength <= 85 ? 1 : 2);
            for (int i = 0; i < sLabels.length; i++) {
                final int val = sVals[i];
                Button sb =
                        makeStudioPill(
                                sLabels[i],
                                "tv-glow-strength:" + val,
                                activeIdx == i,
                                () -> {
                                    a.prefs.edit().putInt(Prefs.TV_AMBIENT_PERCENT, val).apply();
                                    if (a.homeAmbient != null) {
                                        a.homeAmbient.setStrength(Prefs.tvAmbientStrength(val));
                                    }
                                    a.refresh();
                                });
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, a.dp(36));
                if (i > 0) lp.leftMargin = a.dp(8);
                strengthRow.addView(sb, lp);
                if (i == 0) registerTvRightControl(sb);
            }
            studioCard.addView(strengthRow, new LinearLayout.LayoutParams(-1, -2));
        }

        LinearLayout.LayoutParams studioLp = new LinearLayout.LayoutParams(-1, -2);
        studioLp.bottomMargin = a.dp(20);
        a.body.addView(studioCard, studioLp);

        // Card 2: Apple TV Soft Glow Preset Grid (2x3) + Custom Color Tuner
        if (!compact || mode == Prefs.BG_MODE_GRADIENT) {
            LinearLayout themeCard = a.vertical();
            themeCard.setClipChildren(false);
            themeCard.setClipToPadding(false);
            themeCard.setPadding(a.dp(22), a.dp(20), a.dp(22), a.dp(20));
            themeCard.setBackground(
                    TvV17Surface.rounded(0x991a1f29, a.dp(18), 0x24ffffff, a.dp(1)));

            LinearLayout themeHead = a.row();
            themeHead.setGravity(Gravity.CENTER_VERTICAL);
            TextView themeTitle = a.text("客厅全局渐变柔光主题", 15.5f, MainActivity.WHITE);
            themeTitle.setTypeface(null, Typeface.BOLD);
            themeHead.addView(themeTitle, new LinearLayout.LayoutParams(0, -2, 1f));
            Button customBtn =
                    makeStudioPill(
                            "自定义颜色调节",
                            "tv-glow-custom-tuner",
                            mode == Prefs.BG_MODE_GRADIENT
                                    && currentPreset == HomeAmbient.PRESET_CUSTOM,
                            this::showCustomGlowTunerDialog);
            themeHead.addView(customBtn, new LinearLayout.LayoutParams(-2, a.dp(38)));
            themeCard.addView(themeHead, new LinearLayout.LayoutParams(-1, -2));
            a.gap(themeCard, 16);

            for (int r = 0; r < 2; r++) {
                LinearLayout gridRow = a.row();
                gridRow.setClipChildren(false);
                gridRow.setClipToPadding(false);
                for (int c = 0; c < 3; c++) {
                    final int idx = r * 3 + c;
                    final boolean isSelected =
                            mode == Prefs.BG_MODE_GRADIENT && currentPreset == idx;
                    LinearLayout swatch =
                            buildGlowPresetCard(
                                    idx,
                                    HomeAmbient.PRESET_NAMES[idx],
                                    HomeAmbient.PRESET_SUBTITLES[idx],
                                    HomeAmbient.PRESET_LEFT[idx],
                                    HomeAmbient.PRESET_RIGHT[idx],
                                    isSelected);
                    LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, -2, 1f);
                    if (c < 2) lp.rightMargin = a.dp(14);
                    gridRow.addView(swatch, lp);
                    if (c == 0) registerTvRightControl(swatch);
                }
                LinearLayout.LayoutParams rowLp = new LinearLayout.LayoutParams(-1, -2);
                if (r == 0) rowLp.bottomMargin = a.dp(14);
                themeCard.addView(gridRow, rowLp);
            }

            LinearLayout.LayoutParams themeLp = new LinearLayout.LayoutParams(-1, -2);
            themeLp.bottomMargin = a.dp(20);
            a.body.addView(themeCard, themeLp);
        }
    }

    private LinearLayout buildGlowPresetCard(
            final int index,
            String name,
            String subtitle,
            final int leftColor,
            final int rightColor,
            final boolean selected) {
        final LinearLayout card = a.vertical();
        card.setClipChildren(false);
        card.setClipToPadding(false);
        card.setPadding(a.dp(12), a.dp(12), a.dp(12), a.dp(12));
        card.setTag("tv-glow-preset:" + index);
        card.setId(View.generateViewId());
        card.setFocusable(true);
        card.setFocusableInTouchMode(true);
        card.setClickable(true);
        a.pressFeedback(card);

        // Two-tone gradient preview bar
        FrameLayout previewBox = new FrameLayout(a);
        android.graphics.drawable.GradientDrawable grad =
                new android.graphics.drawable.GradientDrawable(
                        android.graphics.drawable.GradientDrawable.Orientation.LEFT_RIGHT,
                        new int[] {leftColor, rightColor});
        grad.setCornerRadius(a.dp(10));
        previewBox.setBackground(grad);
        if (selected) {
            TextView badge = a.text("✓ 当前", 10.5f, MainActivity.WHITE);
            badge.setTypeface(null, Typeface.BOLD);
            badge.setPadding(a.dp(8), a.dp(2), a.dp(8), a.dp(2));
            badge.setBackground(a.bg(0xbb101318, 10));
            FrameLayout.LayoutParams blp =
                    new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.END);
            blp.topMargin = a.dp(6);
            blp.rightMargin = a.dp(6);
            previewBox.addView(badge, blp);
        }
        card.addView(previewBox, new LinearLayout.LayoutParams(-1, a.dp(50)));
        a.gap(card, 9);

        LinearLayout titleRow = a.row();
        titleRow.setGravity(Gravity.CENTER_VERTICAL);
        View dot1 = new View(a);
        dot1.setBackground(a.bg(leftColor, 6));
        LinearLayout.LayoutParams d1 = new LinearLayout.LayoutParams(a.dp(9), a.dp(9));
        d1.rightMargin = a.dp(5);
        titleRow.addView(dot1, d1);
        View dot2 = new View(a);
        dot2.setBackground(a.bg(rightColor, 6));
        LinearLayout.LayoutParams d2 = new LinearLayout.LayoutParams(a.dp(9), a.dp(9));
        d2.rightMargin = a.dp(8);
        titleRow.addView(dot2, d2);
        final TextView titleView = a.text(name, 14, MainActivity.WHITE);
        titleView.setTypeface(null, Typeface.BOLD);
        titleView.setSingleLine(true);
        titleRow.addView(titleView);
        card.addView(titleRow);

        final TextView subView = a.text(subtitle, 11, 0xa8ebebf5);
        subView.setSingleLine(true);
        subView.setEllipsize(android.text.TextUtils.TruncateAt.END);
        subView.setPadding(0, a.dp(3), 0, 0);
        card.addView(subView);

        final int restBg = selected ? 0x36ffffff : 0x5512161f;
        final int restStroke = selected ? 0x9980c2ff : 0x22ffffff;
        final android.graphics.drawable.Drawable restingBg =
                TvV17Surface.rounded(restBg, a.dp(14), restStroke, a.dp(1));
        final android.graphics.drawable.Drawable focusedBg =
                TvV17Surface.rounded(0xfff5f5f7, a.dp(14), 0xffffffff, a.dp(2));
        card.setBackground(restingBg);
        card.setOnFocusChangeListener(
                (v, focused) -> {
                    card.animate().cancel();
                    if (focused) {
                        if (card.getBackground() != focusedBg) card.setBackground(focusedBg);
                        titleView.setTextColor(0xff101013);
                        subView.setTextColor(0xff48484a);
                        float scale = a.reduced ? 1f : 1.03f;
                        if (a.reduced) {
                            card.setScaleX(1f);
                            card.setScaleY(1f);
                        } else {
                            card.animate()
                                    .scaleX(scale)
                                    .scaleY(scale)
                                    .setDuration(70)
                                    .setInterpolator(tvDecel())
                                    .start();
                        }
                        if (a.homeAmbient != null) {
                            a.homeAmbient.previewCustomColors(leftColor, rightColor);
                        }
                    } else {
                        if (card.getBackground() != restingBg) card.setBackground(restingBg);
                        titleView.setTextColor(MainActivity.WHITE);
                        subView.setTextColor(0xa8ebebf5);
                        card.setScaleX(1f);
                        card.setScaleY(1f);
                    }
                });
        card.setOnClickListener(
                v -> {
                    a.prefs
                            .edit()
                            .putInt(Prefs.TV_BG_MODE, Prefs.BG_MODE_GRADIENT)
                            .putInt(Prefs.TV_GLOW_PRESET, index)
                            .putBoolean(Prefs.WALLPAPER_ENABLED, false)
                            .putBoolean(Prefs.HOME_AMBIENT, true)
                            .apply();
                    a.refresh();
                });
        return card;
    }

    private void showCustomGlowTunerDialog() {
        int[] active = HomeAmbient.activeGradientColors(a);
        final float[] leftHsv = new float[3];
        final float[] rightHsv = new float[3];
        Color.colorToHSV(active[0], leftHsv);
        Color.colorToHSV(active[1], rightHsv);
        if (leftHsv[1] < 0.15f) leftHsv[1] = 0.55f;
        if (leftHsv[2] < 0.25f) leftHsv[2] = 0.48f;
        if (rightHsv[1] < 0.15f) rightHsv[1] = 0.55f;
        if (rightHsv[2] < 0.25f) rightHsv[2] = 0.48f;

        LinearLayout panel = a.vertical();
        panel.setPadding(a.dp(6), a.dp(4), a.dp(6), a.dp(4));

        final View previewBar = new View(a);
        LinearLayout.LayoutParams pLp = new LinearLayout.LayoutParams(-1, a.dp(64));
        pLp.bottomMargin = a.dp(14);
        panel.addView(previewBar, pLp);

        final TextView leftHueVal = a.text("", 13, 0xd8ebebf5);
        final TextView leftSatVal = a.text("", 13, 0xd8ebebf5);
        final TextView rightHueVal = a.text("", 13, 0xd8ebebf5);
        final TextView rightSatVal = a.text("", 13, 0xd8ebebf5);

        Runnable syncPreview =
                () -> {
                    int lc = Color.HSVToColor(leftHsv);
                    int rc = Color.HSVToColor(rightHsv);
                    android.graphics.drawable.GradientDrawable gd =
                            new android.graphics.drawable.GradientDrawable(
                                    android.graphics.drawable.GradientDrawable.Orientation
                                            .LEFT_RIGHT,
                                    new int[] {lc, rc});
                    gd.setCornerRadius(a.dp(14));
                    gd.setStroke(a.dp(1), 0x44ffffff);
                    previewBar.setBackground(gd);
                    leftHueVal.setText(Math.round(leftHsv[0]) + "°");
                    leftSatVal.setText(Math.round(leftHsv[1] * 100) + "%");
                    rightHueVal.setText(Math.round(rightHsv[0]) + "°");
                    rightSatVal.setText(Math.round(rightHsv[1] * 100) + "%");
                    if (a.homeAmbient != null) {
                        a.homeAmbient.previewCustomColors(lc, rc);
                    }
                };

        addColorAdjustRow(
                panel,
                "左上主光 · 色相",
                leftHueVal,
                () -> {
                    leftHsv[0] = (leftHsv[0] + 345f) % 360f;
                    syncPreview.run();
                },
                () -> {
                    leftHsv[0] = (leftHsv[0] + 15f) % 360f;
                    syncPreview.run();
                });
        addColorAdjustRow(
                panel,
                "左上主光 · 饱和度",
                leftSatVal,
                () -> {
                    leftHsv[1] = Math.max(0.15f, leftHsv[1] - 0.1f);
                    syncPreview.run();
                },
                () -> {
                    leftHsv[1] = Math.min(0.85f, leftHsv[1] + 0.1f);
                    syncPreview.run();
                });
        addColorAdjustRow(
                panel,
                "右下辅光 · 色相",
                rightHueVal,
                () -> {
                    rightHsv[0] = (rightHsv[0] + 345f) % 360f;
                    syncPreview.run();
                },
                () -> {
                    rightHsv[0] = (rightHsv[0] + 15f) % 360f;
                    syncPreview.run();
                });
        addColorAdjustRow(
                panel,
                "右下辅光 · 饱和度",
                rightSatVal,
                () -> {
                    rightHsv[1] = Math.max(0.15f, rightHsv[1] - 0.1f);
                    syncPreview.run();
                },
                () -> {
                    rightHsv[1] = Math.min(0.85f, rightHsv[1] + 0.1f);
                    syncPreview.run();
                });

        syncPreview.run();

        new AppDialog.Builder(a)
                .setTitle("自定义柔光双色")
                .setView(panel)
                .setNegativeButton(
                        "取消",
                        (d, w) -> {
                            if (a.homeAmbient != null) a.homeAmbient.applyFromPrefs(true);
                        })
                .setPositiveButton(
                        "应用此柔光配色",
                        (d, w) -> {
                            int lc = Color.HSVToColor(leftHsv) & 0xFFFFFF;
                            int rc = Color.HSVToColor(rightHsv) & 0xFFFFFF;
                            a.prefs
                                    .edit()
                                    .putInt(Prefs.TV_BG_MODE, Prefs.BG_MODE_GRADIENT)
                                    .putInt(Prefs.TV_GLOW_PRESET, HomeAmbient.PRESET_CUSTOM)
                                    .putInt(Prefs.TV_GLOW_COLOR_LEFT, lc)
                                    .putInt(Prefs.TV_GLOW_COLOR_RIGHT, rc)
                                    .putBoolean(Prefs.WALLPAPER_ENABLED, false)
                                    .putBoolean(Prefs.HOME_AMBIENT, true)
                                    .apply();
                            a.refresh();
                            a.toast("自定义柔光配色已保存");
                        })
                .show();
    }

    private void addColorAdjustRow(
            LinearLayout parent,
            String label,
            TextView valueText,
            Runnable onMinus,
            Runnable onPlus) {
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(0, a.dp(4), 0, a.dp(4));
        TextView lbl = a.text(label, 14, MainActivity.WHITE);
        row.addView(lbl, new LinearLayout.LayoutParams(0, -2, 1f));
        Button minus = a.navButton("－", "tuner-minus-" + label, onMinus);
        LinearLayout.LayoutParams ml = new LinearLayout.LayoutParams(a.dp(46), a.dp(36));
        row.addView(minus, ml);
        valueText.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams vl = new LinearLayout.LayoutParams(a.dp(62), -2);
        row.addView(valueText, vl);
        Button plus = a.navButton("＋", "tuner-plus-" + label, onPlus);
        LinearLayout.LayoutParams pl = new LinearLayout.LayoutParams(a.dp(46), a.dp(36));
        row.addView(plus, pl);
        parent.addView(row, new LinearLayout.LayoutParams(-1, -2));
    }

    void wallpaper() {
        page("首页壁纸", "支持手机扫码上传本地高清图片、Apple TV 柔光渐变主题、自定义双色调节与剧集封面色调自适应。");
        if (a.isTvDevice()) {
            addTvBackgroundStudioInline(false);
            link(
                    "手机扫码上传替换壁纸",
                    "同一 Wi-Fi 下手机扫码，直接从相册选图传到电视",
                    "wallpaper-qr-upload",
                    () -> new WallpaperUploadDialog(a, a::refresh).show());
        }
        link("选择本地图片", "JPG、PNG、WebP", "wallpaper-file", () -> pick(44, "image/*", false));
        link("从图片地址导入", "输入你自己的 HTTP / HTTPS 图片地址", "wallpaper-url", this::wallpaperUrl);
        ints(
                "壁纸压暗",
                Prefs.WALLPAPER_DIM,
                new String[] {"轻 · 40%", "适中 · 60%", "深 · 80%"},
                new int[] {40, 60, 80},
                60);
        link(
                "切换为封面自适应柔光",
                "跟随首页选中的剧集封面主色调自动渲染柔光背景",
                "wallpaper-reset",
                () -> applyTvBackgroundMode(Prefs.BG_MODE_ADAPTIVE));
        if (new File(a.getFilesDir(), "wallpaper.jpg").exists())
            link(
                    "启用已保存的图片壁纸",
                    "使用上次上传或导入的图片",
                    "wallpaper-enable",
                    () -> applyTvBackgroundMode(Prefs.BG_MODE_WALLPAPER));
    }

    void playback() {
        page("播放与字幕", "作为之后播放的默认设置；播放界面中仍可随时调整。");
        playbackRows();
    }

    void playbackRows() {
        if (a.isTvDevice()) {
            ints(
                    "播放界面样式",
                    Prefs.TV_PLAYER_STYLE,
                    new String[] {"现代悬浮卡片（默认）", "经典双层工具栏"},
                    new int[] {0, 1},
                    0);
            boolean modernPlayerStyle = a.prefs.getInt(Prefs.TV_PLAYER_STYLE, 0) == 0;
            link(
                    "播放工具条按钮顺序",
                    TvPlayerToolbarOrder.settingsSummary(
                            a.prefs.getString(Prefs.TV_PLAYER_TOOLBAR_ORDER, ""),
                            modernPlayerStyle),
                    "setting-" + Prefs.TV_PLAYER_TOOLBAR_ORDER,
                    this::showTvToolbarOrderDialog);
        }
        ints(
                "画面输出",
                Prefs.VIDEO_OUTPUT,
                new String[] {"保真输出 · HDR 与流畅度优先", "兼容输出 · 支持应用内调色"},
                new int[] {0, 1},
                0);
        ints(
                "播放器",
                Prefs.PLAYER_ENGINE,
                new String[] {
                    "Exo (Media3 · 默认)",
                    "MPV 高画质 (libmpv · HDR / Anime4K / ASS)",
                    "IJK 兼容模式 (Media3 + FFmpeg)",
                    "系统播放器"
                },
                new int[] {0, 3, 2, 1},
                0);
        ints(
                "解码方式",
                Prefs.DECODER_MODE,
                new String[] {"自动", "硬件解码", "软件解码优先"},
                new int[] {0, 1, 2},
                0);
        toggle("4K HDR 隧道模式", Prefs.TUNNELED_PLAYBACK, false, null);
        toggle("MPV HDR 自动峰值色调映射 (libplacebo)", Prefs.HDR_TONE_MAPPING, true, null);
        toggle("MPV Anime4K 实时超分滤镜", Prefs.ANIME4K_ENABLED, false, null);
        toggle("HLS 伪装分片实时修正代理", Prefs.HLS_PROXY_ENABLED, true, null);
        toggle("HLS 点播广告分段启发式过滤", Prefs.HLS_AD_STRIP, false, null);
        ints(
                "直链本地分块缓存",
                Prefs.MEDIA_CACHE_MB,
                new String[] {"关闭", "128 MB", "256 MB（默认）", "512 MB", "1024 MB"},
                new int[] {0, 128, 256, 512, 1024},
                256);
        ints(
                "人声与响度增益",
                Prefs.LOUDNESS_BOOST,
                new String[] {"关闭", "+4 dB", "+8 dB", "+12 dB"},
                new int[] {0, 4, 8, 12},
                0);
        toggle("内置 CPython 3.11 爬虫引擎", Prefs.NATIVE_PYTHON_ENABLED, true, a::closeEngines);
        toggle("异步 JS 源 WebView 兜底引擎", Prefs.WEBVIEW_JS_FALLBACK, true, a::closeEngines);
        toggle("优先使用兼容音频解码", Prefs.SOFTWARE_AUDIO, false, null);
        toggle("优先选择 AAC 音轨", Prefs.PREFER_AAC, false, null);
        link("解码组件", "查看本机已加载的音频与视频扩展", "settings-decoders", () -> open(this::decoders));
        ints(
                "画面比例",
                Prefs.ASPECT,
                new String[] {"适应", "铺满", "16:9", "4:3", "裁切填充"},
                new int[] {0, 1, 2, 3, 4},
                0);
        ints(
                "网络缓冲",
                Prefs.BUFFER_SECONDS,
                new String[] {"15 秒 · 节省内存", "30 秒 · 均衡", "50 秒 · 网络波动"},
                new int[] {15, 30, 50},
                30);
        link(
                "默认速度",
                a.prefs.getFloat(Prefs.PLAY_SPEED, 1) + "×",
                "setting-play_speed",
                () -> {
                    String[] speedLabels =
                            new String[] {"0.5×", "0.75×", "1×", "1.25×", "1.5×", "2×"};
                    float[] speedVals = new float[] {.5f, .75f, 1f, 1.25f, 1.5f, 2f};
                    float curSpeed = a.prefs.getFloat(Prefs.PLAY_SPEED, 1f);
                    int curIdx = 2;
                    for (int i = 0; i < speedVals.length; i++) {
                        if (Math.abs(curSpeed - speedVals[i]) < 0.05f) {
                            curIdx = i;
                            break;
                        }
                    }
                    if (!a.isTvDevice()) {
                        MobileShell.showDrawerPicker(
                                a,
                                "默认播放速度",
                                "作为之后进入播放时的初始倍速",
                                speedLabels,
                                curIdx,
                                i -> {
                                    a.prefs.edit().putFloat(Prefs.PLAY_SPEED, speedVals[i]).apply();
                                    a.refresh();
                                });
                        return;
                    }
                    new AppDialog.Builder(a)
                            .setTitle("播放速度")
                            .setItems(
                                    speedLabels,
                                    (d, i) -> {
                                        a.prefs
                                                .edit()
                                                .putFloat(Prefs.PLAY_SPEED, speedVals[i])
                                                .apply();
                                        a.refresh();
                                    })
                            .show();
                });
        toggle("自动播放下一集", Prefs.AUTO_NEXT, true, null);
        if (a.isTvDevice()) {
            toggle("播放中右上角显示进度与时间", Prefs.TV_PLAYER_TOP_RIGHT_HUD, true, null);
        } else {
            toggle("播放页常显时间", Prefs.PLAYER_ALWAYS_SHOW_CLOCK, false, null);
        }
        link(
                "起播画质规格提示",
                PlayerHudPrefs.isStartSpecHudEnabled(a) ? "开启" : "关闭",
                "setting-" + PlayerHudPrefs.KEY_START_SPEC_HUD,
                () -> {
                    PlayerHudPrefs.setStartSpecHudEnabled(
                            a, !PlayerHudPrefs.isStartSpecHudEnabled(a));
                    a.refresh();
                });
        link(
                "播放中底部细进度条",
                PlayerHudPrefs.isSlimProgressEnabled(a) ? "开启" : "关闭",
                "setting-" + PlayerHudPrefs.KEY_SLIM_PROGRESS,
                () -> {
                    PlayerHudPrefs.setSlimProgressEnabled(
                            a, !PlayerHudPrefs.isSlimProgressEnabled(a));
                    a.refresh();
                });
        link(
                "跳过片头片尾 3 秒可取消倒计时",
                PlayerHudPrefs.isSkipCountdownEnabled(a) ? "开启（3 秒倒计时）" : "关闭（立即跳过）",
                "setting-" + PlayerHudPrefs.KEY_SKIP_COUNTDOWN,
                () -> {
                    PlayerHudPrefs.setSkipCountdownEnabled(
                            a, !PlayerHudPrefs.isSkipCountdownEnabled(a));
                    a.refresh();
                });
        if (!a.isTvDevice()) {
            link(
                    "双击屏幕左右两侧",
                    PlayerHudPrefs.doubleTapSidesLabel(PlayerHudPrefs.getDoubleTapSides(a)),
                    "setting-" + PlayerHudPrefs.KEY_DOUBLE_TAP_SIDES,
                    () -> {
                        final String[] labels = {
                            "左右快退/快进 5 秒", "左右快退/快进 10 秒", "左右快退/快进 15 秒", "全屏双击播放 / 暂停"
                        };
                        final String[] vals = {
                            PlayerHudPrefs.SIDES_SEEK_5S,
                            PlayerHudPrefs.SIDES_SEEK_10S,
                            PlayerHudPrefs.SIDES_SEEK_15S,
                            PlayerHudPrefs.SIDES_PLAY_PAUSE
                        };
                        String cur = PlayerHudPrefs.getDoubleTapSides(a);
                        int sel = 1;
                        for (int i = 0; i < vals.length; i++) {
                            if (vals[i].equals(cur)) sel = i;
                        }
                        MobileShell.showDrawerPicker(
                                a,
                                "双击屏幕左右两侧",
                                "支持连击累加快进快退，或切换回全屏双击播/暂",
                                labels,
                                sel,
                                idx -> {
                                    PlayerHudPrefs.setDoubleTapSides(a, vals[idx]);
                                    a.refresh();
                                });
                    });
            link(
                    "双击屏幕中央",
                    PlayerHudPrefs.doubleTapCenterLabel(PlayerHudPrefs.getDoubleTapCenter(a)),
                    "setting-" + PlayerHudPrefs.KEY_DOUBLE_TAP_CENTER,
                    () -> {
                        final String[] labels = {"播放 / 暂停", "切换横竖屏全屏", "关闭双击"};
                        final String[] vals = {
                            PlayerHudPrefs.CENTER_PLAY_PAUSE,
                            PlayerHudPrefs.CENTER_FULLSCREEN,
                            PlayerHudPrefs.CENTER_NONE
                        };
                        String cur = PlayerHudPrefs.getDoubleTapCenter(a);
                        int sel = 0;
                        for (int i = 0; i < vals.length; i++) {
                            if (vals[i].equals(cur)) sel = i;
                        }
                        MobileShell.showDrawerPicker(
                                a,
                                "双击屏幕中央",
                                "自定义播放画面中区双击响应",
                                labels,
                                sel,
                                idx -> {
                                    PlayerHudPrefs.setDoubleTapCenter(a, vals[idx]);
                                    a.refresh();
                                });
                    });
            link(
                    "长按倍速松手恢复",
                    PlayerHudPrefs.longPressRestoreLabel(PlayerHudPrefs.getLongPressRestoreMode(a)),
                    "setting-" + PlayerHudPrefs.KEY_LONG_PRESS_RESTORE_MODE,
                    () -> {
                        boolean isOneX =
                                PlayerHudPrefs.RESTORE_ONE_X.equals(
                                        PlayerHudPrefs.getLongPressRestoreMode(a));
                        PlayerHudPrefs.setLongPressRestoreMode(
                                a,
                                isOneX
                                        ? PlayerHudPrefs.RESTORE_PREVIOUS
                                        : PlayerHudPrefs.RESTORE_ONE_X);
                        a.refresh();
                    });
        }
        ints("循环", Prefs.REPEAT_MODE, new String[] {"关闭", "单集循环", "列表循环"}, new int[] {0, 1, 2}, 0);
        int skipRecordCount = PlaybackControls.countVideoSkipRecords(a);
        link(
                "片头片尾独立记录",
                skipRecordCount <= 0
                        ? "每部影片在播放页独立保存片头片尾，不全局同步"
                        : "已独立记录 " + skipRecordCount + " 部影片 · 点击查看或清空",
                "setting-" + Prefs.VIDEO_SKIP_RECORDS,
                () -> PlaybackControls.showVideoSkipRecordsDialog(a, a::refresh));
        int subSize = Prefs.clampSubtitleSize(a.prefs.getInt(Prefs.SUBTITLE_SIZE, 45));
        int subBottom = Prefs.clampSubtitleBottom(a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24));
        int subStyle = Prefs.clampSubtitleStyle(a.prefs.getInt(Prefs.SUBTITLE_STYLE, 0));
        link(
                a.isTvDevice() ? "字幕大小与位置（全屏预览调校）" : "字幕全屏调试（双指缩放 · 按住拖拽）",
                "字号 "
                        + subSize
                        + " · 底部高度 "
                        + subBottom
                        + "dp · "
                        + SubtitleOverlayView.STYLE_LABELS[subStyle],
                "setting-" + Prefs.SUBTITLE_SIZE,
                () -> PlaybackControls.showSubtitleAdjuster(a, null, a::refresh));
        ints(
                "字幕样式",
                Prefs.SUBTITLE_STYLE,
                SubtitleOverlayView.STYLE_LABELS,
                new int[] {0, 1, 2, 3, 4, 5, 6, 7},
                0);
        ints(
                "自动音轨偏好",
                Prefs.AUDIO_TRACK_PREFERENCE,
                new String[] {"智能默认（自动避开解说音轨）", "优先中文 / 国语", "优先原声 / 片源默认"},
                new int[] {0, 1, 2},
                0);
        toggle("自动加载来源弹幕", Prefs.DANMAKU_DEFAULT, true, null);
        DanmuSettingsPanel.DanmuConfig dmCfg = DanmuSettingsPanel.loadConfig(a, a.isTvDevice());
        String dmSummary = DanmuSettingsPanel.formatConfigSummary(dmCfg);
        link(
                "弹幕设置",
                dmSummary,
                "setting-danmu-panel",
                () -> {
                    android.app.AlertDialog dlg =
                            DanmuSettingsPanel.showDialog(a, a.isTvDevice(), null);
                    dlg.setOnDismissListener(
                            d -> {
                                if (!a.isFinishing()
                                        && (android.os.Build.VERSION.SDK_INT < 17
                                                || !a.isDestroyed())) {
                                    a.refresh();
                                }
                            });
                });
        ints(
                "画面色彩",
                Prefs.PICTURE_EFFECT,
                new String[] {"原始", "明亮", "影院", "柔和"},
                new int[] {0, 1, 2, 3},
                0);
        ints(
                "音效",
                Prefs.AUDIO_EFFECT,
                new String[] {"原声", "影院", "人声清晰", "柔和低音"},
                new int[] {0, 1, 2, 3},
                0);
        a.paragraph(
                "兼容音频解码仅切换音频，不强制视频软解码；AAC 优先仅在媒体包含可用 AAC 音轨时生效，不会转换文件。以上两项用于 Media3。音效取决于电视提供的音频接口。系统播放器支持的字幕和网络格式少于 Media3；播放器中的字幕按钮可导入外部字幕。");
    }

    void showTvToolbarOrderDialog() {
        final boolean modernStyle = a.prefs.getInt(Prefs.TV_PLAYER_STYLE, 0) == 0;
        final boolean reducedTrans = a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
        final String initialSaved = a.prefs.getString(Prefs.TV_PLAYER_TOOLBAR_ORDER, "");
        final java.util.List<String> order =
                TvPlayerToolbarOrder.resolveOrder(initialSaved, modernStyle);
        final int count = order.size();
        if (count == 0) return;

        final View returnFocus = a.getCurrentFocus();
        final String[] grabbedKey = {null};
        final int[] focusedSlot = {0};
        final boolean[] changed = {false};

        final android.app.Dialog dialog = new android.app.Dialog(a);
        dialog.requestWindowFeature(android.view.Window.FEATURE_NO_TITLE);

        LinearLayout panel = a.vertical();
        panel.setTag("tv-toolbar-order-dialog");
        panel.setClipChildren(false);
        panel.setClipToPadding(false);
        panel.setPadding(a.dp(24), a.dp(20), a.dp(24), a.dp(18));
        panel.setBackground(
                TvV17Surface.rounded(
                        reducedTrans ? 0xf6191c23 : 0xee161b25, a.dp(24), 0x30ffffff, a.dp(1)));

        // Header row: title + active player style badge
        LinearLayout titleRow = a.row();
        titleRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView titleView = a.text("自定义播放工具条按钮顺序", 20, MainActivity.WHITE);
        titleView.setTypeface(null, Typeface.BOLD);
        titleRow.addView(titleView, new LinearLayout.LayoutParams(0, -2, 1f));
        TextView stylePill = a.text(modernStyle ? "现代悬浮卡片" : "经典双层工具栏", 11.5f, 0xd8d8e6ff);
        stylePill.setTypeface(null, Typeface.BOLD);
        stylePill.setPadding(a.dp(10), a.dp(4), a.dp(10), a.dp(4));
        stylePill.setBackground(TvV17Surface.rounded(0x28ffffff, a.dp(999), 0x38ffffff, a.dp(1)));
        titleRow.addView(stylePill, new LinearLayout.LayoutParams(-2, -2));
        panel.addView(titleRow, new LinearLayout.LayoutParams(-1, -2));

        TextView subtitle = a.text("上下选择按钮 · 按 ◀ ▶ 直接左移/右移 · 或按确认键抓起后用方向键移动", 12.5f, 0xb2ebebf5);
        subtitle.setPadding(0, a.dp(5), 0, a.dp(12));
        panel.addView(subtitle, new LinearLayout.LayoutParams(-1, -2));

        // Live horizontal toolbar preview strip
        LinearLayout previewBox = a.vertical();
        previewBox.setPadding(a.dp(12), a.dp(9), a.dp(12), a.dp(10));
        previewBox.setBackground(TvV17Surface.rounded(0x7a0d1118, a.dp(14), 0x22ffffff, a.dp(1)));
        TextView previewHeading = a.text("实时预览（从左到右）", 11f, 0x99ebebf5);
        previewHeading.setPadding(a.dp(2), 0, 0, a.dp(7));
        previewBox.addView(previewHeading);

        final HorizontalScrollView previewScroller = new HorizontalScrollView(a);
        previewScroller.setHorizontalScrollBarEnabled(false);
        previewScroller.setFocusable(false);
        previewScroller.setFillViewport(true);
        LinearLayout previewStrip = a.row();
        previewStrip.setTag("tv-toolbar-order-preview");
        previewStrip.setGravity(Gravity.CENTER_VERTICAL);
        final TextView[] previewChips = new TextView[count];
        for (int i = 0; i < count; i++) {
            TextView chip = a.text("", 11.5f, 0xdcebebf5);
            chip.setSingleLine(true);
            chip.setIncludeFontPadding(false);
            chip.setGravity(Gravity.CENTER);
            chip.setPadding(a.dp(9), a.dp(5), a.dp(9), a.dp(5));
            LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(-2, -2);
            if (i > 0) clp.leftMargin = a.dp(6);
            previewStrip.addView(chip, clp);
            previewChips[i] = chip;
        }
        previewScroller.addView(previewStrip, new FrameLayout.LayoutParams(-2, -2));
        previewBox.addView(previewScroller, new LinearLayout.LayoutParams(-1, -2));
        LinearLayout.LayoutParams prevBoxLp = new LinearLayout.LayoutParams(-1, -2);
        prevBoxLp.bottomMargin = a.dp(12);
        panel.addView(previewBox, prevBoxLp);

        // Scrollable reorderable list of persistent row slots
        final LinearLayout listContainer = a.vertical();
        listContainer.setClipChildren(false);
        listContainer.setClipToPadding(false);
        listContainer.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(4));

        final LinearLayout[] rowViews = new LinearLayout[count];
        final TextView[] indexBadges = new TextView[count];
        final TextView[] nameViews = new TextView[count];
        final TextView[] hintViews = new TextView[count];
        final int[] rowStates = new int[count];
        final int[] chipStates = new int[count];
        java.util.Arrays.fill(rowStates, -1);
        java.util.Arrays.fill(chipStates, -1);

        final Runnable persistOrder =
                () -> {
                    String existing = a.prefs.getString(Prefs.TV_PLAYER_TOOLBAR_ORDER, "");
                    String merged =
                            TvPlayerToolbarOrder.mergeEditedOrder(existing, order, modernStyle);
                    a.prefs.edit().putString(Prefs.TV_PLAYER_TOOLBAR_ORDER, merged).apply();
                    changed[0] = true;
                };

        final Runnable syncAll =
                () -> {
                    int focusedRowIdx = -1;
                    for (int i = 0; i < count; i++) {
                        String key = order.get(i);
                        boolean grabbed = key.equals(grabbedKey[0]);
                        boolean focused = rowViews[i].hasFocus();
                        if (focused) focusedRowIdx = i;

                        rowViews[i].setTag("toolbar-order-row:" + key);
                        indexBadges[i].setText(String.valueOf(i + 1));
                        nameViews[i].setText(TvPlayerToolbarOrder.settingsLabel(key));

                        String hintText;
                        if (grabbed) {
                            hintText = "● 移动中 · ▲▼◀▶ 调序 · 确认放下";
                        } else if (focused) {
                            if (i == 0) {
                                hintText = "确认抓起 · 右移 ▶";
                            } else if (i == count - 1) {
                                hintText = "◀ 左移 · 确认抓起";
                            } else {
                                hintText = "◀ 左移 · 确认抓起 · 右移 ▶";
                            }
                        } else {
                            hintText =
                                    (i > 0 ? "◀ " : "   ")
                                            + "第 "
                                            + (i + 1)
                                            + " 位"
                                            + (i < count - 1 ? " ▶" : "   ");
                        }
                        hintViews[i].setText(hintText);

                        int nextRowState = grabbed ? 2 : (focused ? 1 : 0);
                        if (rowStates[i] != nextRowState) {
                            rowStates[i] = nextRowState;
                            if (nextRowState == 2) {
                                rowViews[i].setBackground(
                                        TvV17Surface.rounded(
                                                0xff0a84ff, a.dp(13), 0x9980c2ff, a.dp(1)));
                                indexBadges[i].setBackground(
                                        TvV17Surface.rounded(0x38ffffff, a.dp(999), 0, 0));
                                indexBadges[i].setTextColor(MainActivity.WHITE);
                                nameViews[i].setTextColor(MainActivity.WHITE);
                                hintViews[i].setTextColor(0xeef5f7fb);
                            } else if (nextRowState == 1) {
                                rowViews[i].setBackground(
                                        TvV17Surface.rounded(
                                                0xfff5f5f7, a.dp(13), 0xffffffff, a.dp(1)));
                                indexBadges[i].setBackground(
                                        TvV17Surface.rounded(0x1f101013, a.dp(999), 0, 0));
                                indexBadges[i].setTextColor(0xff101013);
                                nameViews[i].setTextColor(0xff101013);
                                hintViews[i].setTextColor(0xff48484a);
                            } else {
                                rowViews[i].setBackground(
                                        TvV17Surface.rounded(
                                                reducedTrans ? 0xee202632 : 0x8a202632,
                                                a.dp(13),
                                                0x20ffffff,
                                                a.dp(1)));
                                indexBadges[i].setBackground(
                                        TvV17Surface.rounded(0x24ffffff, a.dp(999), 0, 0));
                                indexBadges[i].setTextColor(0xdcebebf5);
                                nameViews[i].setTextColor(MainActivity.WHITE);
                                hintViews[i].setTextColor(0x99ebebf5);
                            }
                        }

                        previewChips[i].setText(
                                (i + 1) + " " + TvPlayerToolbarOrder.shortChipLabel(key));
                        int nextChipState = grabbed ? 2 : (focused ? 1 : 0);
                        if (chipStates[i] != nextChipState) {
                            chipStates[i] = nextChipState;
                            if (nextChipState == 2) {
                                previewChips[i].setBackground(
                                        TvV17Surface.rounded(
                                                0xff0a84ff, a.dp(999), 0x9980c2ff, a.dp(1)));
                                previewChips[i].setTextColor(MainActivity.WHITE);
                                previewChips[i].setTypeface(null, Typeface.BOLD);
                            } else if (nextChipState == 1) {
                                previewChips[i].setBackground(
                                        TvV17Surface.rounded(
                                                0xfff5f5f7, a.dp(999), 0xffffffff, a.dp(1)));
                                previewChips[i].setTextColor(0xff101013);
                                previewChips[i].setTypeface(null, Typeface.BOLD);
                            } else {
                                previewChips[i].setBackground(
                                        TvV17Surface.rounded(
                                                0x26ffffff, a.dp(999), 0x1effffff, a.dp(1)));
                                previewChips[i].setTextColor(0xdcebebf5);
                                previewChips[i].setTypeface(null, Typeface.NORMAL);
                            }
                        }
                    }
                    int activeIdx =
                            focusedRowIdx >= 0
                                    ? focusedRowIdx
                                    : Math.max(0, Math.min(count - 1, focusedSlot[0]));
                    final TextView activeChip = previewChips[activeIdx];
                    previewScroller.post(
                            () -> {
                                int chipCenter = activeChip.getLeft() + activeChip.getWidth() / 2;
                                int targetScroll =
                                        Math.max(0, chipCenter - previewScroller.getWidth() / 2);
                                previewScroller.smoothScrollTo(targetScroll, 0);
                            });
                };

        for (int i = 0; i < count; i++) {
            final int slot = i;
            LinearLayout row = a.row();
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(a.dp(14), a.dp(9), a.dp(14), a.dp(9));
            row.setId(UiCompat.generateViewId());
            row.setFocusable(true);
            row.setFocusableInTouchMode(true);
            row.setClickable(true);
            UiCompat.setDefaultFocusHighlightEnabled(row, false);

            TextView badge = a.text(String.valueOf(i + 1), 12.5f, 0xdcebebf5);
            badge.setTypeface(null, Typeface.BOLD);
            badge.setGravity(Gravity.CENTER);
            badge.setIncludeFontPadding(false);
            LinearLayout.LayoutParams bLp = new LinearLayout.LayoutParams(a.dp(26), a.dp(26));
            bLp.rightMargin = a.dp(12);
            row.addView(badge, bLp);

            TextView name = a.text("", 15f, MainActivity.WHITE);
            name.setTypeface(null, Typeface.BOLD);
            name.setSingleLine(true);
            name.setEllipsize(android.text.TextUtils.TruncateAt.END);
            row.addView(name, new LinearLayout.LayoutParams(0, -2, 1f));

            TextView hint = a.text("", 12f, 0x99ebebf5);
            hint.setSingleLine(true);
            hint.setPadding(a.dp(10), 0, 0, 0);
            row.addView(hint, new LinearLayout.LayoutParams(-2, -2));

            rowViews[slot] = row;
            indexBadges[slot] = badge;
            nameViews[slot] = name;
            hintViews[slot] = hint;

            row.setOnFocusChangeListener(
                    (v, focused) -> {
                        if (focused) {
                            focusedSlot[0] = slot;
                        }
                        syncAll.run();
                    });

            row.setOnClickListener(
                    v -> {
                        String key = order.get(slot);
                        if (key.equals(grabbedKey[0])) {
                            grabbedKey[0] = null;
                        } else {
                            grabbedKey[0] = key;
                        }
                        syncAll.run();
                    });

            row.setOnKeyListener(
                    (v, keyCode, event) -> {
                        boolean down = event.getAction() == android.view.KeyEvent.ACTION_DOWN;
                        boolean isGrabbed = order.get(slot).equals(grabbedKey[0]);
                        if (keyCode == android.view.KeyEvent.KEYCODE_DPAD_LEFT) {
                            if (down && TvPlayerToolbarOrder.moveItem(order, slot, -1)) {
                                persistOrder.run();
                                focusedSlot[0] = slot - 1;
                                rowViews[slot - 1].requestFocus();
                                syncAll.run();
                            }
                            return true;
                        }
                        if (keyCode == android.view.KeyEvent.KEYCODE_DPAD_RIGHT) {
                            if (down && TvPlayerToolbarOrder.moveItem(order, slot, 1)) {
                                persistOrder.run();
                                focusedSlot[0] = slot + 1;
                                rowViews[slot + 1].requestFocus();
                                syncAll.run();
                            }
                            return true;
                        }
                        if (isGrabbed && keyCode == android.view.KeyEvent.KEYCODE_DPAD_UP) {
                            if (down && TvPlayerToolbarOrder.moveItem(order, slot, -1)) {
                                persistOrder.run();
                                focusedSlot[0] = slot - 1;
                                rowViews[slot - 1].requestFocus();
                                syncAll.run();
                            }
                            return true;
                        }
                        if (isGrabbed && keyCode == android.view.KeyEvent.KEYCODE_DPAD_DOWN) {
                            if (down && TvPlayerToolbarOrder.moveItem(order, slot, 1)) {
                                persistOrder.run();
                                focusedSlot[0] = slot + 1;
                                rowViews[slot + 1].requestFocus();
                                syncAll.run();
                            }
                            return true;
                        }
                        return false;
                    });

            LinearLayout.LayoutParams rLp = new LinearLayout.LayoutParams(-1, a.dp(46));
            rLp.bottomMargin = a.dp(6);
            listContainer.addView(row, rLp);
        }

        // Footer buttons: Reset Default + Done
        LinearLayout footer = a.row();
        footer.setGravity(Gravity.CENTER_VERTICAL);
        footer.setClipChildren(false);
        footer.setClipToPadding(false);

        final Button resetBtn =
                a.navButton(
                        "恢复默认顺序",
                        "toolbar-order-reset",
                        () -> {
                            grabbedKey[0] = null;
                            order.clear();
                            order.addAll(TvPlayerToolbarOrder.defaultOrder(modernStyle));
                            a.prefs.edit().remove(Prefs.TV_PLAYER_TOOLBAR_ORDER).apply();
                            changed[0] = true;
                            focusedSlot[0] = 0;
                            syncAll.run();
                            a.toast("已恢复默认按钮顺序");
                        });
        resetBtn.setId(UiCompat.generateViewId());
        UiCompat.setDefaultFocusHighlightEnabled(resetBtn, false);
        resetBtn.setOnFocusChangeListener(
                (v, f) -> {
                    if (f && grabbedKey[0] != null) {
                        grabbedKey[0] = null;
                        syncAll.run();
                    }
                    FocusMotion.style(
                            a,
                            resetBtn,
                            f,
                            0xff282832,
                            MainActivity.WHITE,
                            19,
                            0xffe6e6ee,
                            MainActivity.DARK,
                            false,
                            1.02f);
                });

        final Button doneBtn = a.navButton("完成", "toolbar-order-done", dialog::dismiss);
        doneBtn.setId(UiCompat.generateViewId());
        UiCompat.setDefaultFocusHighlightEnabled(doneBtn, false);
        doneBtn.setOnFocusChangeListener(
                (v, f) -> {
                    if (f && grabbedKey[0] != null) {
                        grabbedKey[0] = null;
                        syncAll.run();
                    }
                    FocusMotion.style(
                            a,
                            doneBtn,
                            f,
                            0xff282832,
                            MainActivity.WHITE,
                            19,
                            0xffe6e6ee,
                            MainActivity.DARK,
                            false,
                            1.02f);
                });

        LinearLayout.LayoutParams resetLp = new LinearLayout.LayoutParams(0, a.dp(42), 1f);
        resetLp.rightMargin = a.dp(10);
        footer.addView(resetBtn, resetLp);
        footer.addView(doneBtn, new LinearLayout.LayoutParams(0, a.dp(42), 1f));

        // Deterministic vertical & horizontal focus links
        for (int i = 0; i < count; i++) {
            rowViews[i].setNextFocusUpId(i == 0 ? rowViews[0].getId() : rowViews[i - 1].getId());
            rowViews[i].setNextFocusDownId(
                    i == count - 1 ? doneBtn.getId() : rowViews[i + 1].getId());
        }
        resetBtn.setNextFocusUpId(rowViews[count - 1].getId());
        resetBtn.setNextFocusDownId(resetBtn.getId());
        resetBtn.setNextFocusLeftId(doneBtn.getId());
        resetBtn.setNextFocusRightId(doneBtn.getId());
        doneBtn.setNextFocusUpId(rowViews[count - 1].getId());
        doneBtn.setNextFocusDownId(doneBtn.getId());
        doneBtn.setNextFocusLeftId(resetBtn.getId());
        doneBtn.setNextFocusRightId(resetBtn.getId());

        TvScrollView scroller = new TvScrollView(a);
        scroller.setFocusFrameEnabled(false);
        scroller.setVerticalScrollBarEnabled(false);
        scroller.addView(listContainer, new ScrollView.LayoutParams(-1, -2));

        FrameLayout viewport =
                new FrameLayout(a) {
                    @Override
                    protected void dispatchDraw(Canvas c) {
                        int save = c.save();
                        c.clipRect(0, 0, getWidth(), getHeight());
                        super.dispatchDraw(c);
                        c.restoreToCount(save);
                    }
                };
        viewport.setTag("scroll-viewport-clip");
        viewport.setClipChildren(true);
        viewport.setClipToPadding(true);
        viewport.addView(scroller, new FrameLayout.LayoutParams(-1, -1));

        int width = Math.min(a.dp(700), Math.max(a.dp(320), a.windowWidth() - a.dp(72)));
        int naturalListH = count * a.dp(52) + a.dp(8);
        int maxListH =
                AppDialog.computeMaxContentHeight(a.windowHeight(), a.dp(248), a.dp(54), a.dp(150));
        panel.addView(
                viewport, new LinearLayout.LayoutParams(-1, Math.min(naturalListH, maxListH)));
        a.gap(panel, 12);
        panel.addView(footer, new LinearLayout.LayoutParams(-1, -2));

        dialog.setOnKeyListener(
                (d, keyCode, event) -> {
                    if (grabbedKey[0] != null
                            && (keyCode == android.view.KeyEvent.KEYCODE_BACK
                                    || keyCode == android.view.KeyEvent.KEYCODE_ESCAPE)) {
                        if (event.getAction() == android.view.KeyEvent.ACTION_UP) {
                            grabbedKey[0] = null;
                            syncAll.run();
                        }
                        return true;
                    }
                    return false;
                });

        dialog.setOnDismissListener(
                d -> {
                    if (changed[0]) {
                        if (a.current != null) {
                            a.current.focus = "setting-" + Prefs.TV_PLAYER_TOOLBAR_ORDER;
                        }
                        a.refresh();
                    } else if (returnFocus != null && UiCompat.isAttached(returnFocus)) {
                        returnFocus.requestFocus();
                    }
                });

        syncAll.run();
        dialog.setContentView(panel);
        dialog.show();
        android.view.Window w = dialog.getWindow();
        if (w != null) {
            w.setBackgroundDrawableResource(android.R.color.transparent);
            w.setLayout(width, -2);
            w.setGravity(Gravity.CENTER);
            w.addFlags(android.view.WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            android.view.WindowManager.LayoutParams attrs = w.getAttributes();
            attrs.dimAmount = 0.56f;
            w.setAttributes(attrs);
            w.getDecorView().setSystemUiVisibility(5894);
        }
        rowViews[0].requestFocus();
        rowViews[0].post(rowViews[0]::requestFocus);
    }

    void data() {
        page("搜索与数据", "搜索默认识别首拼和全拼，并检索配置中全部可搜索来源。");
        contentRows();
        backupRows();
    }

    void content() {
        page("内容与连接", "搜索默认识别首拼和全拼，并检索配置中全部可搜索来源。");
        contentRows();
    }

    void backup() {
        page("数据与备份", "管理同步、备份和本机记录。");
        backupRows();
    }

    void contentRows() {
        ints(
                "同时搜索的来源数",
                Prefs.SEARCH_THREADS,
                new String[] {"2 个 · 轻量", "4 个 · 均衡", "6 个 · 快速"},
                new int[] {2, 4, 6},
                6);
        ints(
                "单个来源等待时间",
                Prefs.SEARCH_TIMEOUT,
                new String[] {"10 秒", "20 秒", "30 秒"},
                new int[] {10, 20, 30},
                20);
        link(
                "导入或更新配置源",
                a.isTvDevice()
                        ? "手机扫码、遥控输入或本地包（支持多行地址自动分组）"
                        : "剪贴板粘贴、网址输入或本地包 (.json/.js/.py/.zip)",
                "settings-import",
                a::importDialog);
        if (a.isTvDevice()) {
            link("已添加源与线路管理", "切换订阅、多源合并自动分组或管理线路", "settings-source-manager", a::chooseOrImport);
        }
        toggle("导入的订阅源每天自动更新", Prefs.SUBSCRIPTION_AUTO_UPDATE, true, null);
        link(
                "立即刷新全部订阅源",
                SourceController.subscriptionAutoUpdateSummary(a),
                "settings-refresh-subs",
                () -> SourceController.runDailyAutoUpdateIfNeeded(a, true));
        link(
                "导入或管理电视直播源",
                "支持叠加多份 M3U / TXT / JSON 源与组播单播配置",
                "settings-live-import",
                () -> SourceController.showLiveImportDialog(a));
        String udpxyAddr = a.prefs.getString(Prefs.LIVE_UDPXY_URL, "");
        link(
                "组播转单播网关 (udpxy)",
                udpxyAddr.isEmpty()
                        ? "配置路由器 udpxy / rtp2httpd 地址播放原画 1080i50 / 4K 组播源"
                        : "当前：" + udpxyAddr,
                "settings-live-udpxy",
                () -> SourceController.showUdpxyDialog(a));
        String epgAddr = a.prefs.getString(Prefs.LIVE_EPG_URL, "");
        link(
                "自定义 XMLTV 节目单 (EPG)",
                epgAddr.isEmpty()
                        ? "支持 .xml / .xml.gz 节目单与回看时移（默认读取列表 x-tvg-url）"
                        : "当前：" + epgAddr,
                "settings-live-epg",
                () -> SourceController.showEpgDialog(a));
        toggle("直播优先最高画质与 IPv6", Prefs.LIVE_HIGH_QUALITY, true, null);
        toggle("跨源同名频道智能聚合", Prefs.LIVE_MERGE_SOURCES, true, null);
        if (a.config != null && a.config.depots.length() > 1) {
            link(
                    "切换影视仓线路",
                    "当前订阅包含 " + a.config.depots.length() + " 个子仓库，点击切换",
                    "settings-depots",
                    () -> SourcePicker.showWarehouses(a));
        }
        toggle("启用来源扩展", Prefs.EXPERIMENTAL_CSP, true, a::closeEngines);
        toggle("仅允许 HTTPS 插件", Prefs.ONLY_ALLOW_HTTPS_PLUGINS, false, a::closeEngines);
        link(
                "网盘与账号",
                "网盘扫码登录、凭据与网盘顺序（由配置提供）",
                "settings-accounts",
                () -> AccountPanel.show(a, null));
        link(
                "挂载 AList 网盘 / 媒体库",
                AlistAccounts.statusSummary(a),
                "settings-alist-mount",
                () -> AlistAccounts.openManager(a, a::refresh));
        if (!a.privateMode) {
            link(
                    "局域网蜘蛛网关",
                    SpiderGatewayDialog.statusSummary(a),
                    "settings-spider-gateway",
                    () -> SpiderGatewayDialog.show(a));
        }
        link(
                "存储权限（网盘扫码 Cookie 保存）",
                a.storagePermissionStatusText(),
                "settings-storage-permission",
                () -> {
                    if (android.os.Build.VERSION.SDK_INT >= 30) {
                        a.openTvStoragePermissionSettings();
                    } else {
                        a.requestRuntimeStoragePermission(a::refresh);
                    }
                });
    }

    void backupRows() {
        if (!a.privateMode) {
            link(
                    "多端网络同步",
                    CloudSyncDialog.statusSummary(a),
                    "settings-cloud-sync",
                    () -> CloudSyncDialog.show(a, a::refresh));
        }
        link(
                "备份配置与偏好",
                "导出配置与偏好，请妥善保管；不含插件单独保存的登录状态",
                "settings-backup",
                () -> pick(45, "application/json", true));
        link(
                "还原配置与偏好",
                "从 Marco Movie 备份文件还原",
                "settings-restore",
                () -> pick(46, "application/json", false));
        link("观看历史", "查看、继续播放或删除本机观看记录", "settings-history", () -> open(a::historyPage));
        link(
                "重置观看历史（保留损坏备份）",
                "清空本机观看记录并解除损坏锁定，已生成的本地备份继续保留",
                "settings-reset-history",
                () ->
                        confirm(
                                "重置观看历史（保留损坏备份）？",
                                () -> {
                                    final boolean wasCorrupted =
                                            WatchHistory.isCorrupted()
                                                    || a.prefs.getBoolean(
                                                            WatchHistory.CORRUPTED_PREF, false);
                                    final java.util.List<WatchHistory.Entry> prev =
                                            wasCorrupted
                                                    ? java.util.Collections.emptyList()
                                                    : a.watchHistory();
                                    a.clearWatchHistory(
                                            () -> {
                                                if (!wasCorrupted) {
                                                    CloudSyncDialog.onHistoryCleared(a, prev);
                                                }
                                                a.toast("已重置观看历史");
                                                a.refresh();
                                            });
                                }));
        link(
                "清除搜索记录",
                "清除最近搜索，保留网盘登录",
                "settings-clear-history",
                () ->
                        confirm(
                                "清除搜索记录？",
                                () -> {
                                    a.prefs.edit().remove(Prefs.GLOBAL_SEARCH_HISTORY).apply();
                                    a.refresh();
                                }));
        link(
                "重新加载首页图片与片单",
                "清除内存与磁盘中的首页缓存",
                "settings-clear-images",
                () -> {
                    a.images.evictAll();
                    a.homeData.clear();
                    try {
                        File snapDir = new File(a.getCacheDir(), "home_snap_v1");
                        File[] files = snapDir.listFiles();
                        if (files != null) for (File f : files) f.delete();
                    } catch (Throwable ignored) {
                    }
                    a.toast("已清除首页缓存");
                });
        link("运行日志", "查看本机最近异常与诊断记录", "settings-logs", this::diagnostics);
        if (!a.privateMode) {
            int pendingCrashes = CrashReportStore.loadUnsubmittedReports(a.getFilesDir()).size();
            String crashSub =
                    pendingCrashes > 0
                            ? ("待提交 " + pendingCrashes + " 条崩溃日志 · 自动提交 GitHub Issue / 扫码导出")
                            : "闪退自动留痕，支持一键提交 GitHub Issue 或扫码导出脱敏日志";
            link(
                    "崩溃日志与问题反馈",
                    crashSub,
                    "settings-crash-feedback",
                    () -> CrashReportDialog.show(a, true));
        }
        link(
                "重新查看新手引导",
                "重温功能导览并重新启用首播手势提示",
                "settings-replay-onboarding",
                () -> {
                    OnboardingScreen.resetForReplay(a);
                    a.showOnboarding(true);
                });
        link(
                "恢复播放与外观默认设置",
                "保留来源配置和网盘登录",
                "settings-reset",
                () ->
                        confirm(
                                "恢复默认设置？",
                                () -> {
                                    android.content.SharedPreferences.Editor edit = a.prefs.edit();
                                    for (String key : KEYS) edit.remove(key);
                                    edit.remove(Prefs.TV_PLAYER_TOOLBAR_ORDER);
                                    edit.apply();
                                    TvNavConfig.reset(a);
                                    a.reduced = false;
                                    a.recreate();
                                }));
        a.paragraph(
                "Marco Movie "
                        + UpdateManager.installedVersion(a)
                        + " · 作者 Pilipala · github.com/Pilipala9919/MarcoMovie。本产品仅为工具，不含任何影视资源；内容与配置请自行合法获取。播放能力取决于服务授权和设备支持。");
    }

    void confirm(String title, Runnable action) {
        new AppDialog.Builder(a)
                .setTitle(title)
                .setNegativeButton("取消", null)
                .setPositiveButton("确定", (d, i) -> action.run())
                .show();
    }

    void diagnostics() {
        String text = AppLog.dump();
        new AppDialog.Builder(a)
                .setTitle("运行日志")
                .setMessage(text.isEmpty() ? "当前运行正常，暂无异常或告警记录。" : text)
                .setNeutralButton(
                        "清空记录",
                        (d, i) -> {
                            AppLog.clear();
                            a.toast("已清空运行日志");
                        })
                .setPositiveButton("关闭", null)
                .show();
    }

    void toggle(String title, String key, boolean defaultValue, Runnable after) {
        boolean tv = a.isTvDevice();
        boolean initial = a.prefs.getBoolean(key, defaultValue);
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(
                a.dp(tv ? 22 : 18), a.dp(tv ? 18 : 14), a.dp(tv ? 22 : 18), a.dp(tv ? 18 : 14));
        MobileShell.SettingIconView icon =
                new MobileShell.SettingIconView(
                        a, MobileShell.SettingIconView.kindForSetting(key, title));
        LinearLayout.LayoutParams iconLp =
                new LinearLayout.LayoutParams(a.dp(tv ? 36 : 38), a.dp(tv ? 36 : 38));
        iconLp.rightMargin = a.dp(tv ? 16 : 14);
        row.addView(icon, iconLp);
        LinearLayout copy = a.vertical();
        final TextView titleView = a.text(title, tv ? 16 : 17, MainActivity.WHITE);
        titleView.setTypeface(null, Typeface.BOLD);
        copy.addView(titleView);
        final TextView caption = a.text(initial ? "开启" : "关闭", 12.5f, 0xa8ebebf5);
        caption.setPadding(0, a.dp(3), 0, 0);
        if (!tv) copy.addView(caption);
        row.addView(copy, new LinearLayout.LayoutParams(0, -2, 1));

        if (tv) {
            caption.setPadding(a.dp(10), 0, a.dp(8), 0);
            row.addView(caption);
        }

        final MobileShell.IosSwitchView toggleSwitch = new MobileShell.IosSwitchView(a, initial);
        LinearLayout.LayoutParams switchLp = new LinearLayout.LayoutParams(a.dp(50), a.dp(30));
        switchLp.leftMargin = a.dp(8);
        row.addView(toggleSwitch, switchLp);

        row.setTag("setting-" + key);
        row.setId(View.generateViewId());
        row.setFocusable(tv);
        row.setFocusableInTouchMode(tv);
        row.setClickable(true);
        final int surface =
                tv && a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false)
                        ? 0xee1c212b
                        : 0xbf1a1f29;
        final android.graphics.drawable.Drawable restingBg =
                tv
                        ? TvV17Surface.rounded(surface, a.dp(14), 0x22ffffff, a.dp(1))
                        : a.bg(0xff222226, 14);
        final android.graphics.drawable.Drawable focusedBg =
                tv ? TvV17Surface.rounded(0xfff5f5f7, a.dp(14), 0xffffffff, a.dp(1)) : null;
        row.setBackground(restingBg);
        row.setOnFocusChangeListener(
                (v, f) -> {
                    if (!tv) {
                        FocusMotion.style(
                                a,
                                row,
                                f,
                                0xff222226,
                                0xff37373e,
                                14,
                                MainActivity.WHITE,
                                MainActivity.WHITE,
                                true,
                                1.008f);
                        return;
                    }
                    row.animate().cancel();
                    if (f) {
                        if (row.getBackground() != focusedBg) row.setBackground(focusedBg);
                        titleView.setTextColor(0xff101013);
                        caption.setTextColor(0xff48484a);
                        float scale = a.reduced ? 1f : 1.014f;
                        if (a.reduced) {
                            row.setScaleX(1f);
                            row.setScaleY(1f);
                        } else {
                            row.animate()
                                    .scaleX(scale)
                                    .scaleY(scale)
                                    .setDuration(70)
                                    .setInterpolator(tvDecel())
                                    .start();
                        }
                    } else {
                        if (row.getBackground() != restingBg) row.setBackground(restingBg);
                        titleView.setTextColor(MainActivity.WHITE);
                        caption.setTextColor(0xa8ebebf5);
                        row.setScaleX(1f);
                        row.setScaleY(1f);
                    }
                });
        if (tv) {
            a.pressFeedback(row);
            registerTvRightControl(row);
        } else {
            MobileShell.bindCardTouchFeedback(a, row, a.bg(0xff222226, 14), a.bg(0xff303038, 14));
        }
        row.setOnClickListener(
                v -> {
                    final boolean current = a.prefs.getBoolean(key, defaultValue);
                    final boolean nextVal = !current;
                    Runnable applyChange =
                            () -> {
                                a.prefs.edit().putBoolean(key, nextVal).apply();
                                toggleSwitch.setChecked(nextVal, !a.reduced);
                                caption.setText(nextVal ? "开启" : "关闭");
                                if (after != null) after.run();
                                if (key.equals(Prefs.WALLPAPER_ENABLED)) {
                                    a.refresh();
                                }
                            };
                    if (key.equals(Prefs.EXPERIMENTAL_CSP) && nextVal && !current) {
                        confirm("运行配置源提供的扩展？请仅使用你信任的配置。", applyChange);
                    } else {
                        applyChange.run();
                    }
                });
        LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(-1, -2);
        size.bottomMargin = a.dp(14);
        a.body.addView(row, size);
    }

    void ints(String title, String key, String[] labels, int[] values, int fallback) {
        int current = a.prefs.getInt(key, fallback), selected = 0;
        for (int i = 0; i < values.length; i++) if (current == values[i]) selected = i;
        final int choice = selected;
        link(
                title,
                labels[selected],
                "setting-" + key,
                () -> {
                    if (!a.isTvDevice()) {
                        MobileShell.showDrawerPicker(
                                a,
                                title,
                                "在下方抽屉中选择预设选项",
                                labels,
                                choice,
                                index -> {
                                    a.prefs.edit().putInt(key, values[index]).apply();
                                    a.refresh();
                                });
                        return;
                    }
                    new AppDialog.Builder(a)
                            .setTitle(title)
                            .setSingleChoiceItems(
                                    labels,
                                    choice,
                                    (dialog, index) -> {
                                        a.prefs.edit().putInt(key, values[index]).apply();
                                        dialog.dismiss();
                                        a.refresh();
                                    })
                            .setNegativeButton("取消", null)
                            .show();
                });
    }

    void pick(int request, String mime, boolean create) {
        if (a.privateMode && (request == 45 || request == 46)) {
            a.toast("请先退出隐私空间，再导出或恢复公开备份");
            return;
        }
        try {
            Intent intent =
                    new Intent(
                            create ? Intent.ACTION_CREATE_DOCUMENT : Intent.ACTION_OPEN_DOCUMENT);
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            intent.setType(mime);
            if (create) intent.putExtra(Intent.EXTRA_TITLE, "MarcoMovie-backup.json");
            a.startActivityForResult(intent, request);
        } catch (Exception error) {
            a.notice("电视没有文件选择器。壁纸也可以通过图片地址导入；文件导入导出需要安装文件管理器。");
        }
    }

    void wallpaperUrl() {
        AddressInput input = new AddressInput(a, "https://…/wallpaper.jpg", "");
        new AppDialog.Builder(a)
                .setTitle("壁纸图片地址")
                .setView(input)
                .setNegativeButton("取消", null)
                .setPositiveButton(
                        "导入",
                        (d, i) -> {
                            String address = input.value();
                            if (!Cms.isHttp(address)) {
                                a.notice("请输入 HTTP 或 HTTPS 图片地址。");
                                return;
                            }
                            a.worker.execute(
                                    () -> {
                                        try {
                                            java.net.HttpURLConnection connection =
                                                    (java.net.HttpURLConnection)
                                                            new java.net.URL(
                                                                            Cms.normalizeHttp(
                                                                                    address))
                                                                    .openConnection();
                                            connection.setConnectTimeout(15000);
                                            connection.setReadTimeout(15000);
                                            try (InputStream stream = connection.getInputStream()) {
                                                saveWallpaper(a, stream);
                                            } finally {
                                                connection.disconnect();
                                            }
                                            a.ui.post(
                                                    () -> {
                                                        a.refresh();
                                                        a.toast("壁纸已更新");
                                                    });
                                        } catch (Exception error) {
                                            a.ui.post(() -> a.notice("图片无法读取，请检查图片地址和格式。"));
                                        }
                                    });
                        })
                .show();
    }

    static void saveWallpaper(MainActivity a, InputStream stream) throws Exception {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        byte[] chunk = new byte[8192];
        int length;
        while ((length = stream.read(chunk)) != -1) {
            if (bytes.size() + length > 16 * 1024 * 1024) throw new IOException("Image too large");
            bytes.write(chunk, 0, length);
        }
        byte[] data = bytes.toByteArray();
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(data, 0, data.length, options);
        if (options.outWidth <= 0 || options.outHeight <= 0) throw new IOException("Invalid image");
        options.inSampleSize = 1;
        while (options.outWidth / options.inSampleSize > 1920
                || options.outHeight / options.inSampleSize > 1080) options.inSampleSize *= 2;
        options.inJustDecodeBounds = false;
        Bitmap image = BitmapFactory.decodeByteArray(data, 0, data.length, options);
        if (image == null) throw new IOException("Invalid image");
        File temporary = new File(a.getFilesDir(), "wallpaper.tmp");
        try {
            try (OutputStream output = new FileOutputStream(temporary)) {
                if (!image.compress(Bitmap.CompressFormat.JPEG, 90, output))
                    throw new IOException("Encoding failed");
            }
            if (!temporary.renameTo(new File(a.getFilesDir(), "wallpaper.jpg")))
                throw new IOException("Unable to save wallpaper");
        } finally {
            image.recycle();
            temporary.delete();
        }
        a.prefs
                .edit()
                .putInt(Prefs.TV_BG_MODE, Prefs.BG_MODE_WALLPAPER)
                .putBoolean(Prefs.WALLPAPER_ENABLED, true)
                .apply();
    }

    static final String[] KEYS = Prefs.KEYS;

    static void result(MainActivity a, int request, Uri uri) {
        if (a.privateMode && (request == 45 || request == 46)) return;
        a.worker.execute(
                () -> {
                    try {
                        if (request == 44) {
                            try (InputStream input = a.getContentResolver().openInputStream(uri)) {
                                saveWallpaper(a, input);
                            }
                        } else if (request == 45) {
                            Object exportedConfig = org.json.JSONObject.NULL;
                            if (a.config != null && a.config.raw != null) {
                                try {
                                    String cleanRaw = Cms.withoutComments(a.config.raw).trim();
                                    exportedConfig =
                                            cleanRaw.startsWith("{")
                                                    ? new org.json.JSONObject(cleanRaw)
                                                    : a.config.raw;
                                } catch (Exception ignored) {
                                    exportedConfig = a.config.raw;
                                }
                            }
                            org.json.JSONObject backup =
                                    new org.json.JSONObject()
                                            .put("format", "MarcoMovie-1")
                                            .put("schema", "marco-movie-backup")
                                            .put("version", 1)
                                            .put("origin", a.configOrigin)
                                            .put("configOrigin", a.configOrigin)
                                            .put("config", exportedConfig);
                            org.json.JSONObject settings = new org.json.JSONObject();
                            for (String key : KEYS)
                                if (a.prefs.contains(key))
                                    settings.put(key, a.prefs.getAll().get(key));
                            for (String dataKey :
                                    new String[] {
                                        Prefs.SELECTED_SITE,
                                        Prefs.TV_PLAYER_TOOLBAR_ORDER,
                                        Prefs.LIVE_UDPXY_URL,
                                        Prefs.LIVE_EPG_URL,
                                        Prefs.LIVE_SOURCES_JSON,
                                        Prefs.WATCH_HISTORY,
                                        Prefs.FAVORITES,
                                        Prefs.GLOBAL_SEARCH_HISTORY
                                    }) {
                                if (a.prefs.contains(dataKey)) {
                                    String clean =
                                            Prefs.sanitizeUserData(
                                                    dataKey, a.prefs.getString(dataKey, ""));
                                    if (clean != null) settings.put(dataKey, clean);
                                }
                            }
                            String savedLiveUrl = a.prefs.getString(Prefs.LIVE_URL, "");
                            if (Cms.isHttp(savedLiveUrl)) {
                                settings.put(Prefs.LIVE_URL, Cms.normalizeHttp(savedLiveUrl));
                                settings.put(
                                        Prefs.LIVE_NAME,
                                        a.prefs.getString(Prefs.LIVE_NAME, "自定义直播源"));
                            }
                            try {
                                ConfigLibrary lib = new ConfigLibrary(a.configStore.directory);
                                org.json.JSONArray subs = new org.json.JSONArray();
                                for (ConfigLibrary.Entry entry : lib.entries()) {
                                    String rawSub = lib.raw(entry);
                                    if (rawSub != null && !rawSub.trim().isEmpty()) {
                                        subs.put(
                                                new org.json.JSONObject()
                                                        .put("id", entry.id)
                                                        .put("name", entry.name)
                                                        .put("url", entry.origin)
                                                        .put("rawContent", rawSub)
                                                        .put("enabled", true)
                                                        .put("isPrivate", false));
                                    }
                                }
                                if (subs.length() > 0) {
                                    settings.put("saved_subscriptions", subs);
                                }
                            } catch (Exception ignored) {
                            }
                            backup.put("settings", settings);
                            try (OutputStream output =
                                    a.getContentResolver().openOutputStream(uri, "wt")) {
                                output.write(backup.toString(2).getBytes("UTF-8"));
                            }
                        } else if (request == 46) {
                            org.json.JSONObject backup;
                            try (InputStream input = a.getContentResolver().openInputStream(uri)) {
                                backup =
                                        new org.json.JSONObject(
                                                Cms.withoutComments(Cms.read(input, Cms.MAX_JSON)));
                            }
                            if (!Prefs.isBackupObject(
                                    backup.optString("format", null),
                                    backup.optString("schema", null),
                                    backup.optInt("version", 0)))
                                throw new IOException("Invalid backup");
                            final String origin =
                                    backup.has("origin") && !backup.optString("origin").isEmpty()
                                            ? backup.optString("origin", "")
                                            : backup.optString("configOrigin", "");
                            final String configJson;
                            if (!backup.has("config") || backup.isNull("config")) {
                                configJson = null;
                            } else {
                                configJson = Prefs.extractBackupConfigJson(backup.opt("config"));
                                if (configJson == null)
                                    throw new IOException("Invalid backup config");
                            }
                            final Cms.Config config =
                                    configJson == null ? null : Cms.parseConfig(configJson, origin);
                            final org.json.JSONObject settings = backup.optJSONObject("settings");
                            final org.json.JSONArray savedSubscriptions =
                                    settings == null
                                            ? null
                                            : settings.optJSONArray("saved_subscriptions");
                            if (savedSubscriptions != null) {
                                for (int i = 0; i < savedSubscriptions.length(); i++) {
                                    org.json.JSONObject sub = savedSubscriptions.getJSONObject(i);
                                    String subRaw = sub.optString("rawContent", "").trim();
                                    String subOrigin = sub.optString("url", "");
                                    if (!subRaw.isEmpty()) {
                                        Cms.parseConfig(subRaw, subOrigin);
                                    }
                                }
                            }
                            if (settings != null) {
                                for (String key :
                                        new String[] {
                                            Prefs.WATCH_HISTORY,
                                            Prefs.FAVORITES,
                                            Prefs.GLOBAL_SEARCH_HISTORY
                                        }) {
                                    if (!settings.has(key)) continue;
                                    org.json.JSONArray rows =
                                            new org.json.JSONArray(
                                                    String.valueOf(settings.get(key)));
                                    for (int i = 0; i < rows.length(); i++) {
                                        if (Prefs.GLOBAL_SEARCH_HISTORY.equals(key)) {
                                            if (!(rows.get(i) instanceof String))
                                                throw new IOException("Invalid search history");
                                        } else {
                                            org.json.JSONObject item = rows.getJSONObject(i);
                                            if (item.optString("id").isEmpty()
                                                    || item.optString("site").isEmpty())
                                                throw new IOException("Invalid bookmark");
                                        }
                                    }
                                }
                            }
                            a.ui.post(
                                    () ->
                                            new AppDialog.Builder(a)
                                                    .setTitle("还原备份？")
                                                    .setMessage("将替换本机来源配置与外观、播放偏好。网盘账号保持不变。")
                                                    .setNegativeButton("取消", null)
                                                    .setPositiveButton(
                                                            "还原",
                                                            (d, i) -> {
                                                                try {
                                                                    int oldScale =
                                                                            a.prefs.getInt(
                                                                                    Prefs
                                                                                            .UI_SCALE_PERCENT,
                                                                                    100);
                                                                    restoreSettings(a, settings);
                                                                    if (savedSubscriptions
                                                                            != null) {
                                                                        try {
                                                                            ConfigLibrary lib =
                                                                                    new ConfigLibrary(
                                                                                            a.configStore
                                                                                                    .directory);
                                                                            for (int idx = 0;
                                                                                    idx
                                                                                            < savedSubscriptions
                                                                                                    .length();
                                                                                    idx++) {
                                                                                org.json.JSONObject
                                                                                        sub =
                                                                                                savedSubscriptions
                                                                                                        .optJSONObject(
                                                                                                                idx);
                                                                                if (sub == null)
                                                                                    continue;
                                                                                String subRaw =
                                                                                        sub.optString(
                                                                                                        "rawContent",
                                                                                                        "")
                                                                                                .trim();
                                                                                if (subRaw
                                                                                        .isEmpty())
                                                                                    continue;
                                                                                lib
                                                                                        .rememberIfAbsent(
                                                                                                subRaw,
                                                                                                sub
                                                                                                        .optString(
                                                                                                                "url",
                                                                                                                ""),
                                                                                                sub
                                                                                                        .optString(
                                                                                                                "name",
                                                                                                                "已恢复的订阅"),
                                                                                                "");
                                                                            }
                                                                        } catch (
                                                                                Exception ignored) {
                                                                        }
                                                                    }
                                                                    if (config != null)
                                                                        a.saveConfig(
                                                                                config, origin);
                                                                    else a.refresh();
                                                                    if (oldScale
                                                                            != a.prefs.getInt(
                                                                                    Prefs
                                                                                            .UI_SCALE_PERCENT,
                                                                                    100))
                                                                        a.recreate();
                                                                } catch (Exception error) {
                                                                    AppLog.w(
                                                                            "Settings",
                                                                            "restoreSettings failed",
                                                                            error);
                                                                    a.notice("备份无法还原。");
                                                                }
                                                            })
                                                    .show());
                            return;
                        }
                        a.ui.post(
                                () -> {
                                    a.refresh();
                                    a.toast(request == 45 ? "备份已保存" : "壁纸已更新");
                                });
                    } catch (Exception error) {
                        AppLog.w("Settings", "file result " + request + " failed", error);
                        a.ui.post(() -> a.notice("文件无法处理。请检查文件格式与可用存储空间。"));
                    }
                });
    }

    static void restoreSettings(MainActivity a, org.json.JSONObject settings) {
        if (settings == null) return;
        android.content.SharedPreferences.Editor edit = a.prefs.edit();
        for (String key : KEYS) {
            Object clean = Prefs.sanitizeSetting(key, settings.opt(key));
            if (clean instanceof Boolean) edit.putBoolean(key, (Boolean) clean);
            else if (clean instanceof Float) edit.putFloat(key, (Float) clean);
            else if (clean instanceof Integer) edit.putInt(key, (Integer) clean);
        }
        for (String dataKey :
                new String[] {
                    Prefs.SELECTED_SITE,
                    Prefs.TV_PLAYER_TOOLBAR_ORDER,
                    Prefs.LIVE_UDPXY_URL,
                    Prefs.LIVE_EPG_URL,
                    Prefs.LIVE_SOURCES_JSON,
                    Prefs.LIVE_URL,
                    Prefs.LIVE_NAME,
                    Prefs.FAVORITES,
                    Prefs.GLOBAL_SEARCH_HISTORY
                }) {
            if (settings.has(dataKey)) {
                String cleanData = Prefs.sanitizeUserData(dataKey, settings.opt(dataKey));
                if (cleanData != null) {
                    edit.putString(dataKey, cleanData);
                }
            }
        }
        edit.apply();
        if (settings.has(Prefs.WATCH_HISTORY) && !settings.isNull(Prefs.WATCH_HISTORY)) {
            Object rawHistory = settings.opt(Prefs.WATCH_HISTORY);
            final boolean validCandidate = WatchHistory.validateBackupJson(rawHistory) != null;
            if (!validCandidate) {
                a.notice("备份中的观看历史格式错误，未能恢复观看历史。");
            }
            WatchHistory.enqueueBackupRestore(
                    a.historyPersistence(),
                    rawHistory,
                    restored ->
                            a.ui.post(
                                    () -> {
                                        if (a.isFinishing() || a.isDestroyed()) return;
                                        if (!restored) {
                                            if (validCandidate) {
                                                a.notice("备份中的观看历史格式错误，未能恢复观看历史。");
                                            }
                                        } else if (a.current != null && a.player == null) {
                                            a.refresh();
                                        }
                                    }));
        }
        a.reduced = a.prefs.getBoolean(Prefs.REDUCED, false);
    }
}
