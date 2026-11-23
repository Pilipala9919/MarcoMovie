package com.pilipala.marcomovie;

import android.graphics.Color;
import android.graphics.Typeface;
import android.net.Uri;
import android.text.Editable;
import android.text.TextUtils;
import android.text.TextWatcher;
import android.view.Gravity;
import android.view.Surface;
import android.view.View;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

/**
 * Redesigned Mobile Live TV Page:
 * - Portrait top {@code 16:9} inline live preview window (instant channel preview, EPG info, stream
 *   line switcher, and {@code ⛶ 全屏} button into landscape fullscreen live player)
 * - Bottom dual-column Group sidebar (left) + Channel & EPG list (right).
 */
final class MobileLivePage {
    private MobileLivePage() {}

    static void render(final MobileRootShell shell, final FrameLayout container) {
        final MainActivity a = shell.a;
        LinearLayout page = a.vertical();
        container.addView(page, new FrameLayout.LayoutParams(-1, -1));

        final List<LiveCatalog.Source> sources = LiveController.sourcesFor(a);
        if (sources.isEmpty()) {
            page.setGravity(Gravity.CENTER_HORIZONTAL);
            page.setPadding(a.dp(24), a.statusBarHeight() + a.dp(64), a.dp(24), a.dp(106));
            TextView hint = a.text("尚未导入电视直播源（支持 M3U / TXT / JSON 与组播单播）", 14, MainActivity.MUTED);
            hint.setGravity(Gravity.CENTER);
            page.addView(hint);
            a.gap(page, 18);
            TextView btn = a.text("＋ 导入电视直播源", 14, 0xff08120e);
            btn.setTypeface(null, Typeface.BOLD);
            btn.setGravity(Gravity.CENTER);
            btn.setPadding(a.dp(20), a.dp(13), a.dp(20), a.dp(13));
            btn.setBackground(a.bg(a.mobileAccentColor(), 999));
            UiWidgets.bindTouchFeedback(btn);
            btn.setOnClickListener(v -> SourceController.showLiveImportDialog(a));
            page.addView(btn, new LinearLayout.LayoutParams(-1, -2));
            return;
        }

        // 1. Top Header: Live source chips + quick filter input
        LinearLayout header = a.vertical();
        header.setPadding(a.dp(14), a.statusBarHeight() + a.dp(8), a.dp(14), a.dp(6));
        page.addView(header, new LinearLayout.LayoutParams(-1, -2));

        LinearLayout topRow = a.row();
        topRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView title = a.text("电视直播", 19, Color.WHITE);
        title.setTypeface(null, Typeface.BOLD);
        topRow.addView(title, new LinearLayout.LayoutParams(0, -2, 1f));

        final EditText filterInput = new EditText(a);
        filterInput.setHint("搜频道…");
        filterInput.setHintTextColor(0xff7c858e);
        filterInput.setTextColor(Color.WHITE);
        filterInput.setTextSize(12.5f);
        filterInput.setSingleLine(true);
        filterInput.setPadding(a.dp(12), a.dp(5), a.dp(12), a.dp(5));
        filterInput.setBackground(
                UiWidgets.glassBg(0xd01e2623, 0xc4141a18, a.dp(999), a.dp(0.8f), 0x30ffffff));
        topRow.addView(filterInput, new LinearLayout.LayoutParams(a.dp(148), -2));
        header.addView(topRow, new LinearLayout.LayoutParams(-1, -2));

        HorizontalScrollView srcHsv = new HorizontalScrollView(a);
        srcHsv.setHorizontalScrollBarEnabled(false);
        srcHsv.setPadding(0, a.dp(7), 0, a.dp(2));
        final LinearLayout srcRow = a.row();
        srcHsv.addView(srcRow);
        header.addView(srcHsv, new LinearLayout.LayoutParams(-1, -2));

        // 2. Portrait 16:9 Inline Live Stage
        int stageH =
                a.isPortrait() ? Math.round((a.windowWidth() - a.dp(24)) * 9f / 16f) : a.dp(168);
        final FrameLayout liveStage = new FrameLayout(a);
        liveStage.setClipToOutline(true);
        liveStage.setBackground(a.bg(0xff050706, 16));
        LinearLayout.LayoutParams stageLp = new LinearLayout.LayoutParams(-1, stageH);
        stageLp.setMargins(a.dp(12), a.dp(2), a.dp(12), a.dp(8));
        page.addView(liveStage, stageLp);

        final VideoOutput previewSurface = new VideoOutput(a, true);
        liveStage.addView(previewSurface, new FrameLayout.LayoutParams(-1, -1, Gravity.CENTER));

        LinearLayout stageHud = a.row();
        stageHud.setGravity(Gravity.CENTER_VERTICAL);
        stageHud.setPadding(a.dp(12), a.dp(8), a.dp(10), a.dp(8));
        stageHud.setBackground(a.bg(0x99080c0a, 0));
        final TextView liveNowLabel = a.text("点选下方频道开始预览", 12.5f, Color.WHITE);
        liveNowLabel.setTypeface(null, Typeface.BOLD);
        liveNowLabel.setSingleLine(true);
        liveNowLabel.setEllipsize(TextUtils.TruncateAt.END);
        stageHud.addView(liveNowLabel, new LinearLayout.LayoutParams(0, -2, 1f));

        final TextView lineBtn = a.text("换线", 11.5f, 0xffe5e7eb);
        lineBtn.setPadding(a.dp(10), a.dp(4), a.dp(10), a.dp(4));
        lineBtn.setBackground(a.bg(0x38ffffff, 999));
        lineBtn.setVisibility(View.GONE);
        UiWidgets.bindTouchFeedback(lineBtn);
        LinearLayout.LayoutParams lbLp = new LinearLayout.LayoutParams(-2, -2);
        lbLp.rightMargin = a.dp(6);
        stageHud.addView(lineBtn, lbLp);

        final TextView fsBtn = a.text("⛶ 全屏", 11.5f, 0xff08120e);
        fsBtn.setTypeface(null, Typeface.BOLD);
        fsBtn.setPadding(a.dp(11), a.dp(4), a.dp(11), a.dp(4));
        fsBtn.setBackground(a.bg(a.mobileAccentColor(), 999));
        fsBtn.setVisibility(View.GONE);
        UiWidgets.bindTouchFeedback(fsBtn);
        stageHud.addView(fsBtn, new LinearLayout.LayoutParams(-2, -2));
        liveStage.addView(stageHud, new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM));

        final MoviePlayer[] inlineLivePlayer = {null};
        final Surface[] readySurface = {null};
        final LiveCatalog.Source[] curSource = {null};
        final LiveCatalog.Channel[] curChannel = {null};
        final LiveCatalog.Stream[] curStream = {null};

        final Runnable stopPreview =
                () -> {
                    if (inlineLivePlayer[0] != null) {
                        try {
                            inlineLivePlayer[0].release();
                        } catch (Exception ignored) {
                        }
                        inlineLivePlayer[0] = null;
                    }
                };
        liveStage.addOnAttachStateChangeListener(
                new View.OnAttachStateChangeListener() {
                    @Override
                    public void onViewAttachedToWindow(View v) {}

                    @Override
                    public void onViewDetachedFromWindow(View v) {
                        stopPreview.run();
                    }
                });

        final Runnable startPreview =
                () -> {
                    stopPreview.run();
                    final LiveCatalog.Channel ch = curChannel[0];
                    final LiveCatalog.Stream st = curStream[0];
                    if (ch == null || st == null || readySurface[0] == null) return;
                    liveNowLabel.setText("正在连接：" + ch.name + " …");
                    fsBtn.setVisibility(View.VISIBLE);
                    lineBtn.setVisibility(ch.streams.size() > 1 ? View.VISIBLE : View.GONE);
                    final int ticket = a.generation;
                    a.worker.execute(
                            () -> {
                                try {
                                    MoviePlayer mp = new MoviePlayer(a);
                                    mp.configureDefaultAudio();
                                    mp.setDataSource(
                                            a,
                                            Uri.parse(LocalProxy.rewrite(st.url)),
                                            Collections.emptyMap());
                                    a.ui.post(
                                            () -> {
                                                if (a.isFinishing()
                                                        || ticket != a.generation
                                                        || !liveStage.isAttachedToWindow()
                                                        || readySurface[0] == null) {
                                                    mp.release();
                                                    return;
                                                }
                                                inlineLivePlayer[0] = mp;
                                                mp.setSurface(readySurface[0]);
                                                mp.setOnPreparedListener(
                                                        p -> {
                                                            liveNowLabel.setText(
                                                                    "● 直播 · " + ch.name);
                                                            p.start();
                                                        });
                                                mp.prepareAsync();
                                            });
                                } catch (Exception e) {
                                    a.ui.post(
                                            () -> liveNowLabel.setText(ch.name + " 预览失败，可点全屏切换内核"));
                                }
                            });
                };

        previewSurface.listen(
                new VideoOutput.Listener() {
                    @Override
                    public void available(Surface value) {
                        readySurface[0] = value;
                        if (curChannel[0] != null && inlineLivePlayer[0] == null) {
                            startPreview.run();
                        } else if (inlineLivePlayer[0] != null) {
                            inlineLivePlayer[0].setSurface(value);
                        }
                    }

                    @Override
                    public void resized(int width, int height) {
                        if (inlineLivePlayer[0] != null) {
                            inlineLivePlayer[0].setSurfaceSize(width, height);
                        }
                    }

                    @Override
                    public void destroyed() {
                        readySurface[0] = null;
                        if (inlineLivePlayer[0] != null) {
                            inlineLivePlayer[0].setSurface(null);
                        }
                    }
                });

        fsBtn.setOnClickListener(
                v -> {
                    if (curSource[0] != null && curChannel[0] != null && curStream[0] != null) {
                        stopPreview.run();
                        a.playLive(curSource[0], curChannel[0], curStream[0]);
                    }
                });
        lineBtn.setOnClickListener(
                v -> {
                    final LiveCatalog.Channel ch = curChannel[0];
                    if (ch == null || ch.streams.size() <= 1) return;
                    String[] labels = LiveController.streamLabelsFor(a, ch);
                    int curIdx = Math.max(0, ch.streams.indexOf(curStream[0]));
                    UiWidgets.showDrawerPicker(
                            a,
                            ch.name + " · 切换直播源线路",
                            "",
                            labels,
                            curIdx,
                            idx -> {
                                curStream[0] = ch.streams.get(idx);
                                startPreview.run();
                            });
                });

        // 3. Bottom Dual-Column Group Sidebar + Channel List
        LinearLayout dualPane = a.row();
        page.addView(dualPane, new LinearLayout.LayoutParams(-1, 0, 1f));

        ScrollView groupSv = new ScrollView(a);
        groupSv.setVerticalScrollBarEnabled(false);
        final LinearLayout groupCol = a.vertical();
        groupCol.setPadding(a.dp(12), a.dp(2), a.dp(6), a.dp(106));
        groupSv.addView(groupCol);
        dualPane.addView(groupSv, new LinearLayout.LayoutParams(a.dp(104), -1));

        ScrollView chanSv = new ScrollView(a);
        chanSv.setVerticalScrollBarEnabled(false);
        shell.bindScrollBehavior(chanSv);
        final LinearLayout chanCol = a.vertical();
        chanCol.setPadding(a.dp(4), a.dp(2), a.dp(12), a.dp(106));
        chanSv.addView(chanCol);
        dualPane.addView(chanSv, new LinearLayout.LayoutParams(0, -1, 1f));

        final int[] srcIdx = {0};
        final int[] grpIdx = {0};
        final LiveCatalog.Catalog[] catHolder = {null};
        final int[] reqSeq = {0};
        final Runnable[] loadCatalog = new Runnable[1];

        final Runnable rebuildColumns =
                new Runnable() {
                    @Override
                    public void run() {
                        groupCol.removeAllViews();
                        chanCol.removeAllViews();
                        LiveCatalog.Catalog cat = catHolder[0];
                        if (cat == null || cat.groups.isEmpty()) return;

                        String q = filterInput.getText().toString().trim().toLowerCase(Locale.ROOT);
                        int accent = a.mobileAccentColor();

                        for (int i = 0; i < cat.groups.size(); i++) {
                            final int gIndex = i;
                            LiveCatalog.Group g = cat.groups.get(i);
                            boolean sel = q.isEmpty() && gIndex == grpIdx[0];
                            TextView gItem =
                                    a.text(
                                            g.name + " (" + g.channels.size() + ")",
                                            12f,
                                            sel ? 0xff08120e : 0xffd1d5db);
                            gItem.setTypeface(null, sel ? Typeface.BOLD : Typeface.NORMAL);
                            gItem.setMaxLines(2);
                            gItem.setEllipsize(TextUtils.TruncateAt.END);
                            gItem.setPadding(a.dp(9), a.dp(9), a.dp(9), a.dp(9));
                            gItem.setBackground(
                                    sel
                                            ? a.bg(accent, 11)
                                            : UiWidgets.glassBg(
                                                    0xb81a2220,
                                                    0xb8121816,
                                                    a.dp(11),
                                                    a.dp(0.6f),
                                                    0x20ffffff));
                            UiWidgets.bindTouchFeedback(gItem);
                            gItem.setOnClickListener(
                                    v -> {
                                        grpIdx[0] = gIndex;
                                        if (!filterInput.getText().toString().isEmpty()) {
                                            filterInput.setText("");
                                        } else {
                                            run();
                                        }
                                    });
                            LinearLayout.LayoutParams gLp = new LinearLayout.LayoutParams(-1, -2);
                            gLp.bottomMargin = a.dp(6);
                            groupCol.addView(gItem, gLp);
                        }

                        int startG =
                                q.isEmpty()
                                        ? Math.max(0, Math.min(cat.groups.size() - 1, grpIdx[0]))
                                        : 0;
                        int endG = q.isEmpty() ? (startG + 1) : cat.groups.size();
                        for (int g = startG; g < endG; g++) {
                            LiveCatalog.Group grp = cat.groups.get(g);
                            for (final LiveCatalog.Channel ch : grp.channels) {
                                if (!q.isEmpty() && !ch.name.toLowerCase(Locale.ROOT).contains(q)) {
                                    continue;
                                }
                                boolean playingThis = (curChannel[0] == ch);
                                LinearLayout row = a.row();
                                row.setGravity(Gravity.CENTER_VERTICAL);
                                row.setPadding(a.dp(10), a.dp(9), a.dp(10), a.dp(9));
                                row.setBackground(
                                        playingThis
                                                ? UiWidgets.glassBg(
                                                        (accent & 0x00ffffff) | 0x33000000,
                                                        (accent & 0x00ffffff) | 0x1e000000,
                                                        a.dp(14),
                                                        a.dp(1f),
                                                        accent)
                                                : UiWidgets.glassBg(
                                                        0xb81b2320,
                                                        0xb8131917,
                                                        a.dp(14),
                                                        a.dp(0.7f),
                                                        0x24ffffff));
                                UiWidgets.bindTouchFeedback(row);

                                TextView badge = buildCallsignBadge(a, ch.name);
                                LinearLayout.LayoutParams bLp =
                                        new LinearLayout.LayoutParams(a.dp(38), a.dp(38));
                                bLp.rightMargin = a.dp(9);
                                row.addView(badge, bLp);

                                LinearLayout info = a.vertical();
                                TextView cName = a.text(ch.name, 13.5f, Color.WHITE);
                                cName.setTypeface(null, Typeface.BOLD);
                                cName.setSingleLine(true);
                                cName.setEllipsize(TextUtils.TruncateAt.END);
                                info.addView(cName);

                                String epg = ch.options.get("epg");
                                String meta =
                                        (epg != null && !epg.trim().isEmpty())
                                                ? ("正在播：" + epg.trim())
                                                : (grp.name
                                                        + " · "
                                                        + (ch.streams.size() > 1
                                                                ? ch.streams.size() + " 条线路"
                                                                : "直连"));
                                TextView sub = a.text(meta, 11f, MainActivity.MUTED);
                                sub.setSingleLine(true);
                                sub.setEllipsize(TextUtils.TruncateAt.END);
                                sub.setPadding(0, a.dp(2), 0, 0);
                                info.addView(sub);
                                row.addView(info, new LinearLayout.LayoutParams(0, -2, 1f));

                                row.setOnClickListener(
                                        v -> {
                                            if (ch.streams.isEmpty()) return;
                                            curSource[0] = sources.get(srcIdx[0]);
                                            curChannel[0] = ch;
                                            curStream[0] = ch.streams.get(0);
                                            startPreview.run();
                                            run();
                                        });
                                row.setOnLongClickListener(
                                        v -> {
                                            if (ch.streams.isEmpty()) return true;
                                            stopPreview.run();
                                            a.playLive(
                                                    sources.get(srcIdx[0]), ch, ch.streams.get(0));
                                            return true;
                                        });

                                LinearLayout.LayoutParams rLp =
                                        new LinearLayout.LayoutParams(-1, -2);
                                rLp.bottomMargin = a.dp(7);
                                chanCol.addView(row, rLp);
                            }
                        }
                    }
                };

        filterInput.addTextChangedListener(
                new TextWatcher() {
                    @Override
                    public void beforeTextChanged(
                            CharSequence s, int start, int count, int after) {}

                    @Override
                    public void onTextChanged(CharSequence s, int start, int before, int count) {}

                    @Override
                    public void afterTextChanged(Editable s) {
                        rebuildColumns.run();
                    }
                });

        loadCatalog[0] =
                () -> {
                    final int myReq = ++reqSeq[0];
                    srcRow.removeAllViews();
                    int accent = a.mobileAccentColor();
                    for (int i = 0; i < sources.size(); i++) {
                        final int idx = i;
                        boolean active = (i == srcIdx[0]);
                        TextView chip =
                                a.text(sources.get(i).name, 12f, active ? 0xff08120e : 0xffe5e7eb);
                        chip.setTypeface(null, active ? Typeface.BOLD : Typeface.NORMAL);
                        chip.setPadding(a.dp(13), a.dp(5), a.dp(13), a.dp(5));
                        chip.setBackground(
                                active
                                        ? a.bg(accent, 999)
                                        : UiWidgets.glassBg(
                                                0xb81d2522,
                                                0xb8141a18,
                                                a.dp(999),
                                                a.dp(0.7f),
                                                0x26ffffff));
                        UiWidgets.bindTouchFeedback(chip);
                        chip.setOnClickListener(
                                v -> {
                                    srcIdx[0] = idx;
                                    grpIdx[0] = 0;
                                    loadCatalog[0].run();
                                });
                        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
                        lp.rightMargin = a.dp(8);
                        srcRow.addView(chip, lp);
                    }
                    TextView addLive = a.text("＋ 管理源", 12f, 0xff93c5fd);
                    addLive.setPadding(a.dp(12), a.dp(5), a.dp(12), a.dp(5));
                    addLive.setBackground(a.bg(0xff1a2430, 999));
                    UiWidgets.bindTouchFeedback(addLive);
                    addLive.setOnClickListener(v -> SourceController.showLiveImportDialog(a));
                    srcRow.addView(addLive);

                    groupCol.removeAllViews();
                    chanCol.removeAllViews();
                    chanCol.addView(a.text("正在加载频道与节目单…", 12.5f, MainActivity.MUTED));
                    final LiveCatalog.Source selSrc = sources.get(srcIdx[0]);
                    final int ticket = a.generation;
                    a.submitPage(
                            () -> {
                                try {
                                    final LiveCatalog.Catalog catalog =
                                            LiveController.loadCatalog(a, selSrc);
                                    a.ui.post(
                                            () -> {
                                                if (a.isFinishing()
                                                        || ticket != a.generation
                                                        || myReq != reqSeq[0]) return;
                                                catHolder[0] = catalog;
                                                a.liveSession = new LiveSession(selSrc, catalog);
                                                if (curChannel[0] == null
                                                        && !catalog.groups.isEmpty()
                                                        && !catalog.groups
                                                                .get(0)
                                                                .channels
                                                                .isEmpty()) {
                                                    LiveCatalog.Channel first =
                                                            catalog.groups.get(0).channels.get(0);
                                                    if (!first.streams.isEmpty()) {
                                                        curSource[0] = selSrc;
                                                        curChannel[0] = first;
                                                        curStream[0] = first.streams.get(0);
                                                        startPreview.run();
                                                    }
                                                }
                                                rebuildColumns.run();
                                            });
                                } catch (Exception e) {
                                    a.ui.post(
                                            () -> {
                                                if (a.isFinishing()
                                                        || ticket != a.generation
                                                        || myReq != reqSeq[0]) return;
                                                chanCol.removeAllViews();
                                                chanCol.addView(
                                                        a.text(
                                                                "读取直播源失败：" + a.message(e),
                                                                12.5f,
                                                                MainActivity.MUTED));
                                            });
                                }
                            });
                };

        loadCatalog[0].run();
    }

    private static TextView buildCallsignBadge(MainActivity a, String rawName) {
        String name = rawName == null ? "TV" : rawName.trim();
        String upper = name.toUpperCase(Locale.ROOT);
        int bgColor = 0xff2563eb;
        String label;
        if (upper.startsWith("CCTV")) {
            bgColor = 0xffe11d48;
            String num = upper.replaceFirst("^CCTV[-\\s]*", "").replaceAll("[^0-9A-Z+]", "");
            if (num.length() > 3) num = num.substring(0, 3);
            label = num.isEmpty() ? "CCTV" : ("CC\n" + num);
        } else if (name.contains("卫视")) {
            bgColor = 0xffd97706;
            String p = name.replaceAll("卫视.*$", "").trim();
            label = p.length() >= 2 ? p.substring(0, 2) : "卫视";
        } else if (upper.contains("4K") || upper.contains("8K")) {
            bgColor = 0xff7c3aed;
            label = upper.contains("8K") ? "8K" : "4K";
        } else {
            String clean = name.replaceAll("[\\[\\(（【].*?[\\]\\)）】]", "").trim();
            label = clean.length() >= 2 ? clean.substring(0, 2) : (clean.isEmpty() ? "TV" : clean);
        }
        TextView tv = a.text(label, 10.5f, Color.WHITE);
        tv.setTypeface(null, Typeface.BOLD);
        tv.setGravity(Gravity.CENTER);
        tv.setBackground(a.bg(bgColor, 10));
        return tv;
    }
}
