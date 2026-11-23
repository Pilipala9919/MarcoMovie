package com.pilipala.marcomovie;

import android.graphics.Rect;
import android.graphics.Typeface;
import android.text.TextUtils;
import android.view.*;
import android.widget.*;
import java.util.*;

/**
 * Category-scoped TV filter panel: renders all source-advertised (or smart fallback) filter rows in
 * horizontally scrollable tracks with auto-centering D-pad focus, plus inline clear/collapse
 * controls, and folds into a compact summary bar while browsing the poster grid.
 */
final class InlineFilters extends LinearLayout {
    final HomeScreen home;
    final MainActivity a;
    final List<List<View>> rows = new ArrayList<>();
    final Map<TextView, String[]> choices = new LinkedHashMap<>();
    LinearLayout summaryRow;
    TextView summaryLabel, expandButton, resetButton;
    TextView expandedClearBtn, expandedCollapseBtn;
    String schema = "";
    String mode = "none";

    InlineFilters(HomeScreen screen) {
        super(screen.a);
        home = screen;
        a = home.a;
        setOrientation(VERTICAL);
        setTag("home-inline-filters");
        setPadding(a.dp(12), a.dp(8), a.dp(10), a.dp(8));
        setBackground(a.bg(0x66222833, 18));
        setVisibility(GONE);
    }

    boolean canShowForCurrentCategory() {
        return a.isTvDevice()
                && home.snapshot != null
                && !SourceController.isConfigOrNetdiskSite(home.site)
                && home.state != null
                && !home.state.category.isEmpty();
    }

    void clearViews() {
        if (hasFocus()) {
            boolean wasApplying = home.applyingFilters;
            home.applyingFilters = true;
            try {
                View safe =
                        home.filterToggle != null && home.filterToggle.isShown()
                                ? home.filterToggle
                                : home.selectedTab();
                if (safe != null) safe.requestFocus();
            } finally {
                home.applyingFilters = wasApplying;
            }
        }
        removeAllViews();
        rows.clear();
        choices.clear();
        summaryRow = null;
        summaryLabel = null;
        expandButton = null;
        resetButton = null;
        expandedClearBtn = null;
        expandedCollapseBtn = null;
    }

    void render() {
        if (!canShowForCurrentCategory()) {
            if (!"none".equals(mode)) {
                clearViews();
                mode = "none";
                schema = "";
            }
            setVisibility(GONE);
            return;
        }
        List<VideoFilters.Definition> definitions = home.filterDefinitions();
        if (home.state.filtersExpanded) {
            boolean remoteBacked = VideoFilters.hasRemoteDefinitions(definitions);
            StringBuilder signature = new StringBuilder(remoteBacked ? "R|" : "L|");
            for (VideoFilters.Definition def : definitions) {
                signature
                        .append(def.dimension)
                        .append(':')
                        .append(def.key)
                        .append(':')
                        .append(def.label)
                        .append(':');
                for (VideoFilters.Choice choice : def.choices)
                    signature
                            .append(choice.value.length())
                            .append(':')
                            .append(choice.value)
                            .append(choice.label.length())
                            .append(':')
                            .append(choice.label);
            }
            if (!"expanded".equals(mode) || !signature.toString().equals(schema)) {
                String focus =
                        hasFocus() && a.getCurrentFocus() != null
                                ? String.valueOf(a.getCurrentFocus().getTag())
                                : null;
                clearViews();
                mode = "expanded";
                schema = signature.toString();
                setPadding(a.dp(12), a.dp(8), a.dp(10), a.dp(8));
                android.graphics.drawable.GradientDrawable panelBg = a.bg(0x70212734, 18);
                panelBg.setStroke(Math.max(1, a.dp(0.8f)), 0x26ffffff);
                setBackground(panelBg);

                LinearLayout header = a.row();
                header.setGravity(Gravity.CENTER_VERTICAL);
                header.setPadding(a.dp(2), 0, a.dp(2), a.dp(6));
                TextView badge =
                        a.text(
                                remoteBacked ? "片源筛选" : "智能筛选",
                                10.5f * home.navScale,
                                remoteBacked ? 0xff4ade80 : 0xff7dd3fc);
                badge.setTypeface(null, Typeface.BOLD);
                badge.setSingleLine(true);
                badge.setPadding(a.dp(8), a.dp(2.5f), a.dp(8), a.dp(2.5f));
                badge.setBackground(a.bg(remoteBacked ? 0x2a30d158 : 0x2a38bdf8, 999));
                header.addView(badge, new LayoutParams(-2, -2));

                TextView hint =
                        a.text(
                                remoteBacked
                                        ? "  直接请求片源筛选接口，点选下方条件实时刷新"
                                        : "  自动匹配片源子分类或本机影片资料，点选实时刷新",
                                11f * home.navScale,
                                0xb8cbd5e1);
                hint.setSingleLine(true);
                hint.setEllipsize(TextUtils.TruncateAt.END);
                header.addView(hint, new LayoutParams(0, -2, 1f));
                addView(header, new LayoutParams(-1, -2));

                for (VideoFilters.Definition def : definitions) addRow(def);
                addExpandedFooterRow();

                if (focus != null && focus.startsWith("home-filter")) {
                    View replacement = findViewWithTag(focus);
                    if (replacement != null) replacement.requestFocus();
                }
            }
            if (expandedClearBtn != null) {
                expandedClearBtn.setText(
                        home.state.selectedFilters.isEmpty()
                                ? "清空筛选"
                                : "清空筛选 (" + home.state.selectedFilters.size() + ")");
                styleAction(expandedClearBtn);
            }
            if (expandedCollapseBtn != null) styleAction(expandedCollapseBtn);
            setVisibility(VISIBLE);
            for (TextView button : choices.keySet()) style(button);
            return;
        }
        if (home.state.selectedFilters.isEmpty()) {
            if (!"none".equals(mode)) {
                clearViews();
                mode = "none";
                schema = "";
            }
            setVisibility(GONE);
            return;
        }
        StringBuilder summary = new StringBuilder("已选筛选：");
        boolean first = true;
        for (VideoFilters.Definition def : definitions) {
            String val = home.state.selectedFilters.get(def.dimension);
            if (val == null || val.isEmpty()) continue;
            if (!first) summary.append(" · ");
            summary.append(def.labelFor(val));
            first = false;
        }
        if (first) {
            for (String val : home.state.selectedFilters.values()) {
                if (val == null || val.isEmpty()) continue;
                if (!first) summary.append(" · ");
                summary.append(val);
                first = false;
            }
        }
        if (!"summary".equals(mode) || summaryRow == null) {
            clearViews();
            mode = "summary";
            schema = "";
            setPadding(a.dp(14), a.dp(5), a.dp(8), a.dp(5));
            android.graphics.drawable.GradientDrawable barBg = a.bg(0x66222833, 16);
            barBg.setStroke(Math.max(1, a.dp(0.8f)), 0x26ffffff);
            setBackground(barBg);
            summaryRow = a.row();
            summaryRow.setTag("home-filter-summary");
            summaryRow.setGravity(Gravity.CENTER_VERTICAL);
            summaryLabel = a.text("", 12f * home.navScale, 0xffe4ecf7);
            summaryLabel.setTag("home-filter-summary-text");
            summaryLabel.setSingleLine(true);
            summaryLabel.setIncludeFontPadding(false);
            summaryLabel.setEllipsize(TextUtils.TruncateAt.END);
            summaryRow.addView(summaryLabel, new LayoutParams(0, -2, 1));

            expandButton =
                    actionChip(
                            "修改筛选",
                            "home-filter-expand",
                            () -> {
                                boolean wasApplying = home.applyingFilters;
                                home.applyingFilters = true;
                                try {
                                    home.state.filtersExpanded = true;
                                    render();
                                    home.updateTabs();
                                    home.wireNavigation();
                                    View target = firstSelectedChip();
                                    if (target != null) target.requestFocus();
                                } finally {
                                    home.applyingFilters = wasApplying;
                                }
                            });
            LayoutParams expandLp = new LayoutParams(-2, a.dp(Math.round(30 * home.navScale)));
            expandLp.leftMargin = a.dp(10);
            summaryRow.addView(expandButton, expandLp);

            resetButton =
                    actionChip(
                            "清空",
                            "home-filter-reset",
                            () -> {
                                home.state.selectedFilters.clear();
                                home.state.filtersExpanded = false;
                                home.applyFilters();
                            });
            LayoutParams resetLp = new LayoutParams(-2, a.dp(Math.round(30 * home.navScale)));
            resetLp.leftMargin = a.dp(6);
            summaryRow.addView(resetButton, resetLp);
            addView(summaryRow, new LayoutParams(-1, -2));
        }
        summaryLabel.setText(summary.toString());
        styleAction(expandButton);
        styleAction(resetButton);
        setVisibility(VISIBLE);
    }

    private void addExpandedFooterRow() {
        LinearLayout footer = a.row();
        footer.setGravity(Gravity.CENTER_VERTICAL);
        footer.setPadding(a.dp(Math.round(82 * home.navScale)), a.dp(4), 0, a.dp(2));
        expandedClearBtn =
                actionChip(
                        "清空筛选",
                        "home-filter-reset",
                        () -> {
                            if (!home.state.selectedFilters.isEmpty()) {
                                home.state.selectedFilters.clear();
                                home.applyFilters();
                            }
                        });
        LayoutParams clearLp = new LayoutParams(-2, a.dp(Math.round(30 * home.navScale)));
        clearLp.rightMargin = a.dp(8);
        footer.addView(expandedClearBtn, clearLp);

        expandedCollapseBtn =
                actionChip(
                        "收起筛选",
                        "home-filter-collapse",
                        () -> {
                            home.state.filtersExpanded = false;
                            render();
                            home.updateTabs();
                            home.wireNavigation();
                            View fallback =
                                    home.filterToggle != null && home.filterToggle.isShown()
                                            ? home.filterToggle
                                            : home.selectedTab();
                            if (fallback != null) fallback.requestFocus();
                        });
        footer.addView(
                expandedCollapseBtn, new LayoutParams(-2, a.dp(Math.round(30 * home.navScale))));
        addView(footer, new LayoutParams(-1, -2));
        List<View> footerLine = new ArrayList<>();
        footerLine.add(expandedClearBtn);
        footerLine.add(expandedCollapseBtn);
        rows.add(footerLine);
    }

    TextView actionChip(String label, String tag, Runnable action) {
        TextView button = a.text(label, 11.5f * home.navScale, MainActivity.WHITE);
        button.setGravity(Gravity.CENTER);
        button.setSingleLine(true);
        button.setIncludeFontPadding(false);
        button.setPadding(a.dp(12), 0, a.dp(12), 0);
        home.focusable(button, tag);
        UiCompat.setDefaultFocusHighlightEnabled(button, false);
        button.setOnClickListener(v -> action.run());
        button.setOnFocusChangeListener(
                (v, focused) -> {
                    styleAction(button);
                    if (focused) post(home::wireNavigation);
                });
        return button;
    }

    void styleAction(TextView button) {
        if (button == null) return;
        boolean focused = button.hasFocus();
        button.setTextColor(focused ? 0xff10141c : 0xffd0dae8);
        android.graphics.drawable.GradientDrawable bg =
                a.bg(focused ? MainActivity.WHITE : 0x443c4758, 15);
        if (focused) bg.setStroke(Math.max(2, a.dp(1.5f)), 0xff7dd3fc);
        else bg.setStroke(Math.max(1, a.dp(1)), 0x448da2bd);
        button.setBackground(bg);
    }

    void addRow(VideoFilters.Definition def) {
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        TextView title = a.text(def.label, 11.5f * home.navScale, MainActivity.MUTED);
        title.setSingleLine(true);
        title.setEllipsize(TextUtils.TruncateAt.END);
        row.addView(title, new LayoutParams(a.dp(Math.round(82 * home.navScale)), -2));
        final HorizontalScrollView viewport = new HorizontalScrollView(a);
        viewport.setHorizontalScrollBarEnabled(false);
        viewport.setOverScrollMode(OVER_SCROLL_NEVER);
        viewport.setSmoothScrollingEnabled(true);
        viewport.setFocusable(false);
        final LinearLayout options = a.row();
        options.setGravity(Gravity.CENTER_VERTICAL);
        List<View> line = new ArrayList<>();
        rows.add(line);
        for (int index = 0; index < def.choices.size(); index++) {
            VideoFilters.Choice choice = def.choices.get(index);
            TextView button = a.text(choice.label, 12f * home.navScale, MainActivity.WHITE);
            button.setGravity(Gravity.CENTER);
            button.setSingleLine(true);
            button.setIncludeFontPadding(false);
            button.setPadding(a.dp(12), 0, a.dp(12), 0);
            home.focusable(button, "home-filter:" + def.dimension + ":" + index);
            UiCompat.setDefaultFocusHighlightEnabled(button, false);
            choices.put(button, new String[] {def.dimension, choice.value});
            button.setOnClickListener(
                    v -> {
                        String previous = home.state.selectedFilters.get(def.dimension);
                        String current = previous == null ? "" : previous;
                        if (choice.value.isEmpty()) {
                            if (current.isEmpty()) return;
                            home.state.selectedFilters.remove(def.dimension);
                        } else if (choice.value.equals(current)) {
                            home.state.selectedFilters.remove(def.dimension);
                        } else {
                            home.state.selectedFilters.put(def.dimension, choice.value);
                        }
                        home.applyFilters();
                    });
            button.setOnFocusChangeListener(
                    (v, focused) -> {
                        style(button);
                        if (focused) {
                            viewport.post(
                                    () -> {
                                        int vw = viewport.getWidth();
                                        if (vw <= 0) return;
                                        int maxScroll = Math.max(0, options.getWidth() - vw);
                                        int desired =
                                                button.getLeft() - (vw - button.getWidth()) / 2;
                                        int targetX = Math.max(0, Math.min(maxScroll, desired));
                                        if (a.reduced) viewport.scrollTo(targetX, 0);
                                        else viewport.smoothScrollTo(targetX, 0);
                                    });
                            post(home::wireNavigation);
                        }
                    });
            LayoutParams size = new LayoutParams(-2, a.dp(Math.round(32 * home.navScale)));
            size.rightMargin = a.dp(5);
            options.addView(button, size);
            line.add(button);
        }
        viewport.addView(options, new HorizontalScrollView.LayoutParams(-2, -1));
        row.addView(viewport, new LayoutParams(0, a.dp(Math.round(38 * home.navScale)), 1));
        addView(row, new LayoutParams(-1, -2));
    }

    void style(TextView button) {
        String[] value = choices.get(button);
        if (value == null) return;
        String selected = home.state.selectedFilters.get(value[0]);
        boolean checked = value[1].equals(selected == null ? "" : selected);
        boolean focused = button.hasFocus();
        button.setSelected(checked);
        button.setTypeface(null, checked || focused ? Typeface.BOLD : Typeface.NORMAL);
        button.setTextColor(focused ? 0xff10141c : (checked ? MainActivity.WHITE : 0xffb8c3d3));
        int fill =
                focused
                        ? MainActivity.WHITE
                        : (checked ? (value[1].isEmpty() ? 0x553b4a62 : 0xcc2563eb) : 0x00000000);
        android.graphics.drawable.GradientDrawable background = a.bg(fill, 16);
        if (focused) {
            background.setStroke(Math.max(2, a.dp(1.5f)), 0xff7dd3fc);
        } else if (checked && !value[1].isEmpty()) {
            background.setStroke(Math.max(1, a.dp(1)), 0xaa93c5fd);
        }
        button.setBackground(background);
        button.setContentDescription(button.getText() + (checked ? "，已选择" : ""));
    }

    boolean expanded() {
        return getVisibility() == VISIBLE && "expanded".equals(mode) && !rows.isEmpty();
    }

    boolean summaryShown() {
        return getVisibility() == VISIBLE
                && "summary".equals(mode)
                && expandButton != null
                && resetButton != null;
    }

    View entryChip(int rowIndex) {
        if (rowIndex < 0 || rowIndex >= rows.size()) return null;
        List<View> line = rows.get(rowIndex);
        for (View option : line) {
            if (option.isSelected()) return option;
        }
        return line.isEmpty() ? null : line.get(0);
    }

    View firstSelectedChip() {
        for (List<View> line : rows) {
            for (int i = 1; i < line.size(); i++) {
                if (line.get(i).isSelected()) return line.get(i);
            }
        }
        return entryChip(0);
    }

    View nearest(List<View> line, View from) {
        int[] location = new int[2];
        from.getLocationOnScreen(location);
        float center = location[0] + from.getWidth() / 2f;
        View best = line.get(0);
        float distance = Float.MAX_VALUE;
        Rect visible = new Rect();
        for (View option : line) {
            if (!option.getGlobalVisibleRect(visible) || visible.width() < option.getWidth() / 2)
                continue;
            float next = Math.abs(visible.exactCenterX() - center);
            if (next < distance) {
                best = option;
                distance = next;
            }
        }
        return best;
    }

    @Override
    protected void onLayout(boolean changed, int l, int t, int r, int b) {
        super.onLayout(changed, l, t, r, b);
        home.wireNavigation();
    }
}
