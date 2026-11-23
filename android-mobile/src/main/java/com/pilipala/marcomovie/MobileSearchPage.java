package com.pilipala.marcomovie;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import org.json.JSONArray;

/**
 * Mobile multi-source concurrent Search Page:
 * - Native soft-keyboard search input + 1-tap clipboard paste + search history chips
 * - Supports both horizontal top site filter bar and BieCuiLe-style left vertical platform sidebar
 *   ({@link Prefs#SEARCH_PLATFORM_SIDEBAR})
 * - Optional title purification ({@link EpisodeNameCleaner#cleanSearchTitle}).
 */
final class MobileSearchPage {
    static final class Hit {
        final Cms.Site site;
        final Cms.Video video;

        Hit(Cms.Site site, Cms.Video video) {
            this.site = site;
            this.video = video;
        }
    }

    private static String cachedKeyword = "";
    private static String cachedStatus = "";
    private static String selectedSiteFilter = "";
    private static final List<Hit> cachedHits = Collections.synchronizedList(new ArrayList<>());

    private MobileSearchPage() {}

    static void clearCachedResults() {
        cachedHits.clear();
        cachedKeyword = "";
        cachedStatus = "";
        selectedSiteFilter = "";
    }

    static void render(final MobileRootShell shell, final FrameLayout container) {
        final MainActivity a = shell.a;
        LinearLayout page = a.vertical();
        page.setPadding(a.dp(16), a.statusBarHeight() + a.dp(10), a.dp(16), 0);
        container.addView(page, new FrameLayout.LayoutParams(-1, -1));

        // 1. Search Input Bar
        LinearLayout searchBar = a.row();
        searchBar.setGravity(Gravity.CENTER_VERTICAL);
        searchBar.setPadding(a.dp(14), a.dp(6), a.dp(8), a.dp(6));
        searchBar.setBackground(
                UiWidgets.glassBg(0xd81d2623, 0xd8131917, a.dp(999), a.dp(0.9f), 0x38ffffff));

        final EditText input = new EditText(a);
        input.setHint("搜索电影、剧集、动漫、演员…");
        input.setHintTextColor(0xff7c858e);
        input.setTextColor(Color.WHITE);
        input.setTextSize(14.5f);
        input.setSingleLine(true);
        input.setImeOptions(EditorInfo.IME_ACTION_SEARCH);
        input.setBackgroundColor(Color.TRANSPARENT);
        input.setPadding(a.dp(4), a.dp(6), a.dp(8), a.dp(6));
        searchBar.addView(input, new LinearLayout.LayoutParams(0, -2, 1f));

        TextView pasteChip = a.text("粘贴", 12f, 0xffd1d5db);
        pasteChip.setPadding(a.dp(10), a.dp(6), a.dp(10), a.dp(6));
        pasteChip.setBackground(a.bg(0x22ffffff, 999));
        UiWidgets.bindTouchFeedback(pasteChip);
        LinearLayout.LayoutParams pLp = new LinearLayout.LayoutParams(-2, -2);
        pLp.rightMargin = a.dp(6);
        searchBar.addView(pasteChip, pLp);

        int accent = a.mobileAccentColor();
        TextView goBtn = a.text("搜索", 13f, 0xff08120e);
        goBtn.setTypeface(null, Typeface.BOLD);
        goBtn.setPadding(a.dp(15), a.dp(7), a.dp(15), a.dp(7));
        goBtn.setBackground(a.bg(accent, 999));
        UiWidgets.bindTouchFeedback(goBtn);
        searchBar.addView(goBtn, new LinearLayout.LayoutParams(-2, -2));

        page.addView(searchBar, new LinearLayout.LayoutParams(-1, -2));

        // 2. History chips + status row
        final LinearLayout historySection = a.vertical();
        historySection.setPadding(0, a.dp(10), 0, a.dp(4));
        page.addView(historySection, new LinearLayout.LayoutParams(-1, -2));

        final TextView statusText = a.text("", 12.5f, MainActivity.MUTED);
        statusText.setPadding(a.dp(2), a.dp(6), a.dp(2), a.dp(6));
        page.addView(statusText, new LinearLayout.LayoutParams(-1, -2));

        // 3. Results area (either Top Filter Pills + Vertical Scroll, or Left Sidebar + Right List)
        final FrameLayout resultsStage = new FrameLayout(a);
        page.addView(resultsStage, new LinearLayout.LayoutParams(-1, 0, 1f));

        final int[] searchSeq = {0};
        final Runnable[] runSearch = new Runnable[1];

        final Runnable rebuildResults =
                new Runnable() {
                    @Override
                    public void run() {
                        resultsStage.removeAllViews();
                        List<Hit> snapshot;
                        synchronized (cachedHits) {
                            snapshot = new ArrayList<>(cachedHits);
                        }
                        if (snapshot.isEmpty()) return;

                        Map<String, Integer> siteCounts = new LinkedHashMap<>();
                        Map<String, String> siteNames = new LinkedHashMap<>();
                        for (Hit h : snapshot) {
                            siteCounts.put(
                                    h.site.key,
                                    (siteCounts.containsKey(h.site.key)
                                                    ? siteCounts.get(h.site.key)
                                                    : 0)
                                            + 1);
                            siteNames.put(h.site.key, h.site.name);
                        }
                        if (!selectedSiteFilter.isEmpty()
                                && !siteCounts.containsKey(selectedSiteFilter)) {
                            selectedSiteFilter = "";
                        }

                        boolean useSidebar =
                                a.mobilePrefs().getBoolean(Prefs.SEARCH_PLATFORM_SIDEBAR, false);
                        if (useSidebar) {
                            LinearLayout split = a.row();
                            resultsStage.addView(split, new FrameLayout.LayoutParams(-1, -1));

                            ScrollView leftSv = new ScrollView(a);
                            leftSv.setVerticalScrollBarEnabled(false);
                            LinearLayout leftCol = a.vertical();
                            leftCol.setPadding(0, a.dp(4), a.dp(8), a.dp(104));
                            addPlatformFilterItem(
                                    a,
                                    leftCol,
                                    "全部 (" + snapshot.size() + ")",
                                    selectedSiteFilter.isEmpty(),
                                    true,
                                    () -> {
                                        selectedSiteFilter = "";
                                        run();
                                    });
                            for (Map.Entry<String, Integer> e : siteCounts.entrySet()) {
                                final String sKey = e.getKey();
                                addPlatformFilterItem(
                                        a,
                                        leftCol,
                                        siteNames.get(sKey) + " (" + e.getValue() + ")",
                                        sKey.equals(selectedSiteFilter),
                                        true,
                                        () -> {
                                            selectedSiteFilter = sKey;
                                            run();
                                        });
                            }
                            leftSv.addView(leftCol);
                            split.addView(leftSv, new LinearLayout.LayoutParams(a.dp(104), -1));

                            ScrollView rightSv = new ScrollView(a);
                            rightSv.setVerticalScrollBarEnabled(false);
                            shell.bindScrollBehavior(rightSv);
                            LinearLayout rightCol = a.vertical();
                            rightCol.setPadding(a.dp(4), a.dp(4), 0, a.dp(106));
                            populateHitRows(a, rightCol, snapshot);
                            rightSv.addView(rightCol);
                            split.addView(rightSv, new LinearLayout.LayoutParams(0, -1, 1f));
                        } else {
                            LinearLayout vBox = a.vertical();
                            resultsStage.addView(vBox, new FrameLayout.LayoutParams(-1, -1));

                            HorizontalScrollView topHsv = new HorizontalScrollView(a);
                            topHsv.setHorizontalScrollBarEnabled(false);
                            topHsv.setPadding(0, a.dp(2), 0, a.dp(8));
                            LinearLayout chipRow = a.row();
                            addPlatformFilterItem(
                                    a,
                                    chipRow,
                                    "全部 (" + snapshot.size() + ")",
                                    selectedSiteFilter.isEmpty(),
                                    false,
                                    () -> {
                                        selectedSiteFilter = "";
                                        run();
                                    });
                            for (Map.Entry<String, Integer> e : siteCounts.entrySet()) {
                                final String sKey = e.getKey();
                                addPlatformFilterItem(
                                        a,
                                        chipRow,
                                        siteNames.get(sKey) + " · " + e.getValue(),
                                        sKey.equals(selectedSiteFilter),
                                        false,
                                        () -> {
                                            selectedSiteFilter = sKey;
                                            run();
                                        });
                            }
                            topHsv.addView(chipRow);
                            vBox.addView(topHsv, new LinearLayout.LayoutParams(-1, -2));

                            ScrollView listSv = new ScrollView(a);
                            listSv.setVerticalScrollBarEnabled(false);
                            shell.bindScrollBehavior(listSv);
                            LinearLayout listCol = a.vertical();
                            listCol.setPadding(0, a.dp(2), 0, a.dp(106));
                            populateHitRows(a, listCol, snapshot);
                            listSv.addView(listCol);
                            vBox.addView(listSv, new LinearLayout.LayoutParams(-1, 0, 1f));
                        }
                    }
                };

        final Runnable renderHistory =
                new Runnable() {
                    @Override
                    public void run() {
                        historySection.removeAllViews();
                        List<String> hist = readSearchHistory(a);
                        if (hist.isEmpty()) return;
                        LinearLayout hRow = a.row();
                        hRow.setGravity(Gravity.CENTER_VERTICAL);
                        hRow.addView(
                                a.text("最近搜索", 12f, MainActivity.MUTED),
                                new LinearLayout.LayoutParams(0, -2, 1f));
                        TextView clear = a.text("清空", 12f, 0xffef4444);
                        UiWidgets.bindTouchFeedback(clear);
                        clear.setOnClickListener(
                                v -> {
                                    a.prefs.edit().remove(Prefs.GLOBAL_SEARCH_HISTORY).apply();
                                    run();
                                });
                        hRow.addView(clear);
                        historySection.addView(hRow);

                        HorizontalScrollView hsv = new HorizontalScrollView(a);
                        hsv.setHorizontalScrollBarEnabled(false);
                        hsv.setPadding(0, a.dp(6), 0, 0);
                        LinearLayout pills = a.row();
                        for (final String kw : hist) {
                            TextView p = a.text(kw, 12f, 0xffe5e7eb);
                            p.setPadding(a.dp(12), a.dp(5), a.dp(12), a.dp(5));
                            p.setBackground(a.bg(0xff1c2421, 999));
                            UiWidgets.bindTouchFeedback(p);
                            p.setOnClickListener(
                                    v -> {
                                        input.setText(kw);
                                        input.setSelection(kw.length());
                                        runSearch[0].run();
                                    });
                            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
                            lp.rightMargin = a.dp(8);
                            pills.addView(p, lp);
                        }
                        hsv.addView(pills);
                        historySection.addView(hsv);
                    }
                };

        runSearch[0] =
                () -> {
                    final String q = input.getText().toString().trim();
                    if (q.isEmpty()) {
                        a.toast("请输入搜索关键词");
                        return;
                    }
                    if (a.config == null || a.config.sites.isEmpty()) {
                        UiWidgets.showMobileImportDialog(a);
                        return;
                    }
                    hideSoftKeyboard(a, input);
                    saveSearchHistory(a, q);
                    renderHistory.run();

                    cachedKeyword = q;
                    selectedSiteFilter = "";
                    cachedHits.clear();
                    resultsStage.removeAllViews();

                    final List<Cms.Site> searchable = new ArrayList<>();
                    for (Cms.Site s : a.config.sites) {
                        if (a.available(s) && s.searchable) searchable.add(s);
                    }
                    if (searchable.isEmpty()) {
                        statusText.setText("当前配置中没有可搜索的片源");
                        return;
                    }
                    final int seq = ++searchSeq[0];
                    final int ticket = a.generation;
                    final int total = searchable.size();
                    final int[] doneCount = {0};
                    statusText.setText("正在并发检索 " + total + " 个片源…");

                    int threads = Math.max(2, Math.min(6, a.prefs.getInt(Prefs.SEARCH_THREADS, 6)));
                    final int timeoutSec =
                            Prefs.clampSearchTimeoutSeconds(
                                    a.prefs.getInt(Prefs.SEARCH_TIMEOUT, 20));
                    a.submitPage(
                            () -> {
                                ExecutorService pool = Executors.newFixedThreadPool(threads);
                                try {
                                    List<Future<?>> futures = new ArrayList<>();
                                    for (final Cms.Site site : searchable) {
                                        futures.add(
                                                pool.submit(
                                                        () -> {
                                                            try {
                                                                Cms.Listing res =
                                                                        Cms.listing(
                                                                                a.engine(site)
                                                                                        .search(
                                                                                                q,
                                                                                                1));
                                                                if (res.videos != null
                                                                        && !res.videos.isEmpty()) {
                                                                    for (Cms.Video v : res.videos) {
                                                                        cachedHits.add(
                                                                                new Hit(site, v));
                                                                    }
                                                                }
                                                            } catch (Exception ignored) {
                                                            } finally {
                                                                a.ui.post(
                                                                        () -> {
                                                                            if (a.isFinishing()
                                                                                    || ticket
                                                                                            != a.generation
                                                                                    || seq
                                                                                            != searchSeq[
                                                                                                    0])
                                                                                return;
                                                                            doneCount[0]++;
                                                                            cachedStatus =
                                                                                    "已检索 "
                                                                                            + doneCount[
                                                                                                    0]
                                                                                            + "/"
                                                                                            + total
                                                                                            + " 个片源 · 命中 "
                                                                                            + cachedHits
                                                                                                    .size()
                                                                                            + " 条结果";
                                                                            statusText.setText(
                                                                                    cachedStatus);
                                                                            rebuildResults.run();
                                                                        });
                                                            }
                                                        }));
                                    }
                                    for (Future<?> f : futures) {
                                        try {
                                            f.get(timeoutSec, TimeUnit.SECONDS);
                                        } catch (Exception ignored) {
                                        }
                                    }
                                } finally {
                                    pool.shutdownNow();
                                }
                            });
                };

        goBtn.setOnClickListener(v -> runSearch[0].run());
        input.setOnEditorActionListener(
                (v, actionId, event) -> {
                    if (actionId == EditorInfo.IME_ACTION_SEARCH
                            || (event != null
                                    && event.getKeyCode() == KeyEvent.KEYCODE_ENTER
                                    && event.getAction() == KeyEvent.ACTION_DOWN)) {
                        runSearch[0].run();
                        return true;
                    }
                    return false;
                });
        pasteChip.setOnClickListener(
                v -> {
                    ClipboardManager cm =
                            (ClipboardManager) a.getSystemService(Context.CLIPBOARD_SERVICE);
                    if (cm != null && cm.hasPrimaryClip()) {
                        ClipData clip = cm.getPrimaryClip();
                        if (clip != null
                                && clip.getItemCount() > 0
                                && clip.getItemAt(0).getText() != null) {
                            String txt = clip.getItemAt(0).getText().toString().trim();
                            if (!txt.isEmpty()) {
                                input.setText(txt);
                                input.setSelection(txt.length());
                                runSearch[0].run();
                                return;
                            }
                        }
                    }
                    a.toast("剪贴板为空");
                });

        renderHistory.run();

        if (!MobileRootShell.pendingSearchKeyword.isEmpty()) {
            String kw = MobileRootShell.pendingSearchKeyword;
            MobileRootShell.pendingSearchKeyword = "";
            input.setText(kw);
            input.setSelection(kw.length());
            runSearch[0].run();
        } else if (!cachedKeyword.isEmpty()) {
            input.setText(cachedKeyword);
            statusText.setText(cachedStatus);
            rebuildResults.run();
        }
    }

    private static void addPlatformFilterItem(
            MainActivity a,
            LinearLayout parent,
            String text,
            boolean active,
            boolean verticalSidebar,
            Runnable onTap) {
        int accent = a.mobileAccentColor();
        TextView tv = a.text(text, 12f, active ? 0xff08120e : 0xffe5e7eb);
        tv.setTypeface(null, active ? Typeface.BOLD : Typeface.NORMAL);
        tv.setSingleLine(!verticalSidebar);
        if (verticalSidebar) tv.setMaxLines(2);
        tv.setEllipsize(TextUtils.TruncateAt.END);
        tv.setPadding(
                a.dp(11), a.dp(verticalSidebar ? 9 : 6), a.dp(11), a.dp(verticalSidebar ? 9 : 6));
        tv.setBackground(
                active
                        ? a.bg(accent, verticalSidebar ? 12 : 999)
                        : UiWidgets.glassBg(
                                0xb81c2421,
                                0xb8141a18,
                                a.dp(verticalSidebar ? 12 : 999),
                                a.dp(0.7f),
                                0x24ffffff));
        UiWidgets.bindTouchFeedback(tv);
        tv.setOnClickListener(v -> onTap.run());
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(verticalSidebar ? -1 : -2, -2);
        if (verticalSidebar) lp.bottomMargin = a.dp(7);
        else lp.rightMargin = a.dp(8);
        parent.addView(tv, lp);
    }

    private static void populateHitRows(MainActivity a, LinearLayout parent, List<Hit> hits) {
        boolean cleanTitle = a.mobilePrefs().getBoolean(Prefs.AI_CLEAN_SEARCH, false);
        for (final Hit h : hits) {
            if (!selectedSiteFilter.isEmpty() && !selectedSiteFilter.equals(h.site.key)) continue;
            LinearLayout card = a.row();
            card.setGravity(Gravity.CENTER_VERTICAL);
            card.setPadding(a.dp(10), a.dp(10), a.dp(12), a.dp(10));
            card.setBackground(
                    UiWidgets.glassBg(0xc01b2320, 0xc0131917, a.dp(16), a.dp(0.7f), 0x26ffffff));
            UiWidgets.bindTouchFeedback(card);
            card.setOnClickListener(v -> MobileHomePage.openVideoOrFolder(a, h.site, h.video));

            ImageView pic = new ImageView(a);
            pic.setScaleType(ImageView.ScaleType.CENTER_CROP);
            pic.setBackground(a.bg(0xff232b28, 10));
            pic.setClipToOutline(true);
            if (h.video.poster != null && !h.video.poster.isEmpty()) {
                a.poster(h.video.poster, pic);
            }
            LinearLayout.LayoutParams pLp = new LinearLayout.LayoutParams(a.dp(56), a.dp(78));
            pLp.rightMargin = a.dp(12);
            card.addView(pic, pLp);

            LinearLayout info = a.vertical();
            String displayTitle =
                    cleanTitle ? EpisodeNameCleaner.cleanSearchTitle(h.video.title) : h.video.title;
            TextView t = a.text(displayTitle, 14.5f, Color.WHITE);
            t.setTypeface(null, Typeface.BOLD);
            t.setMaxLines(2);
            t.setEllipsize(TextUtils.TruncateAt.END);
            info.addView(t);

            String meta =
                    h.site.name
                            + (h.video.remarks != null && !h.video.remarks.isEmpty()
                                    ? ("  ·  " + h.video.remarks)
                                    : "");
            TextView sub = a.text(meta, 12f, a.mobileAccentColor());
            sub.setPadding(0, a.dp(5), 0, 0);
            info.addView(sub);

            card.addView(info, new LinearLayout.LayoutParams(0, -2, 1f));
            LinearLayout.LayoutParams cLp = new LinearLayout.LayoutParams(-1, -2);
            cLp.bottomMargin = a.dp(9);
            parent.addView(card, cLp);
        }
    }

    private static List<String> readSearchHistory(MainActivity a) {
        List<String> list = new ArrayList<>();
        try {
            JSONArray arr = new JSONArray(a.prefs.getString(Prefs.GLOBAL_SEARCH_HISTORY, "[]"));
            for (int i = 0; i < Math.min(12, arr.length()); i++) {
                String s = arr.optString(i, "").trim();
                if (!s.isEmpty()) list.add(s);
            }
        } catch (Exception ignored) {
        }
        return list;
    }

    private static void saveSearchHistory(MainActivity a, String kw) {
        try {
            List<String> cur = readSearchHistory(a);
            cur.remove(kw);
            cur.add(0, kw);
            JSONArray arr = new JSONArray();
            for (int i = 0; i < Math.min(15, cur.size()); i++) arr.put(cur.get(i));
            a.prefs.edit().putString(Prefs.GLOBAL_SEARCH_HISTORY, arr.toString()).apply();
        } catch (Exception ignored) {
        }
    }

    private static void hideSoftKeyboard(MainActivity a, View v) {
        try {
            InputMethodManager imm =
                    (InputMethodManager) a.getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm != null) imm.hideSoftInputFromWindow(v.getWindowToken(), 0);
        } catch (Exception ignored) {
        }
    }
}
