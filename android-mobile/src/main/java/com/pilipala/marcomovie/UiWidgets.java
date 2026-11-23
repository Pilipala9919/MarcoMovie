package com.pilipala.marcomovie;

import android.animation.ValueAnimator;
import android.app.Dialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.view.animation.DecelerateInterpolator;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Locale;

/**
 * Shared Liquid Glass surfaces, touch feedback helpers, vector setting icons, iOS switches, and
 * adaptive choice sheets used across core controllers without cross-referencing TV or Mobile
 * screen classes.
 */
final class UiWidgets {
    interface BooleanAction {
        void onToggle(boolean checked);
    }

    private UiWidgets() {}

    static GradientDrawable glassBg(
            MainActivity a, int fillColor, int strokeColor, float radiusDp) {
        GradientDrawable gd = new GradientDrawable();
        if (a.isReducedTransparency()) {
            gd.setColor((fillColor & 0x00ffffff) | 0xf2000000);
        } else {
            gd.setColor(fillColor);
        }
        gd.setCornerRadius(a.dp(radiusDp));
        gd.setStroke(Math.max(1, a.dp(0.8f)), strokeColor);
        return gd;
    }

    static GradientDrawable glassBg(
            int topColor, int bottomColor, float radiusPx, float strokePx, int strokeColor) {
        GradientDrawable gd =
                new GradientDrawable(
                        GradientDrawable.Orientation.TOP_BOTTOM, new int[] {topColor, bottomColor});
        gd.setCornerRadius(radiusPx);
        if (strokePx > 0) {
            gd.setStroke(Math.max(1, Math.round(strokePx)), strokeColor);
        }
        return gd;
    }

    static void bindTouchFeedback(View v) {
        if (v == null) return;
        v.setFocusable(false);
        v.setFocusableInTouchMode(false);
        v.setOnTouchListener(
                (view, event) -> {
                    int action = event.getActionMasked();
                    if (action == MotionEvent.ACTION_DOWN) {
                        view.setAlpha(0.72f);
                    } else if (action == MotionEvent.ACTION_UP
                            || action == MotionEvent.ACTION_CANCEL) {
                        view.setAlpha(1.0f);
                    }
                    return false;
                });
    }

    static void bindCardTouchFeedback(
            MainActivity a, View card, Drawable normalBg, Drawable pressedBg) {
        if (card == null) return;
        card.setOnTouchListener(
                (v, ev) -> {
                    int act = ev.getActionMasked();
                    if (act == MotionEvent.ACTION_DOWN) {
                        if (pressedBg != null) v.setBackground(pressedBg);
                        if (!a.reduced) {
                            v.animate().cancel();
                            v.animate().scaleX(0.986f).scaleY(0.986f).setDuration(80).start();
                        }
                    } else if (act == MotionEvent.ACTION_UP || act == MotionEvent.ACTION_CANCEL) {
                        if (normalBg != null) v.setBackground(normalBg);
                        if (!a.reduced) {
                            v.animate().cancel();
                            v.animate().scaleX(1f).scaleY(1f).setDuration(120).start();
                        }
                    }
                    return false;
                });
    }

    static void showDrawerPicker(
            MainActivity a,
            String title,
            String subtitle,
            String[] options,
            int selectedIndex,
            PlayerBubble.IntAction onSelect) {
        if (a.isTvDevice()) {
            new AppDialog.Builder(a)
                    .setTitle(title)
                    .setSingleChoiceItems(
                            options,
                            Math.max(0, selectedIndex),
                            (d, idx) -> {
                                d.dismiss();
                                if (onSelect != null) onSelect.accept(idx);
                            })
                    .setNegativeButton("取消", null)
                    .show();
            return;
        }
        final Dialog dlg = new Dialog(a);
        dlg.requestWindowFeature(Window.FEATURE_NO_TITLE);
        if (dlg.getWindow() != null) {
            dlg.getWindow().setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
            dlg.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            dlg.getWindow()
                    .setLayout(
                            WindowManager.LayoutParams.MATCH_PARENT,
                            WindowManager.LayoutParams.MATCH_PARENT);
        }

        FrameLayout backdrop = new FrameLayout(a);
        backdrop.setMinimumWidth(a.windowWidth());
        backdrop.setMinimumHeight(a.windowHeight());
        backdrop.setBackgroundColor(0x88000000);
        backdrop.setOnClickListener(v -> dlg.dismiss());

        int sheetWidth =
                a.isPortrait() ? a.windowWidth() : Math.min(a.windowWidth() - a.dp(32), a.dp(540));
        LinearLayout sheet = a.vertical();
        sheet.setClickable(true);
        sheet.setMinimumWidth(sheetWidth);
        sheet.setPadding(a.dp(20), a.dp(12), a.dp(20), a.dp(28));
        GradientDrawable sheetBg =
                new GradientDrawable(
                        GradientDrawable.Orientation.TOP_BOTTOM,
                        new int[] {0xf619221f, 0xfa101614});
        float r = a.dp(26);
        sheetBg.setCornerRadii(new float[] {r, r, r, r, 0, 0, 0, 0});
        sheetBg.setStroke(Math.max(1, a.dp(1)), 0x33ffffff);
        sheet.setBackground(sheetBg);

        View handle = new View(a);
        handle.setBackground(a.bg(0x48ffffff, 999));
        LinearLayout.LayoutParams handleLp = new LinearLayout.LayoutParams(a.dp(40), a.dp(4));
        handleLp.gravity = Gravity.CENTER_HORIZONTAL;
        handleLp.bottomMargin = a.dp(14);
        sheet.addView(handle, handleLp);

        LinearLayout headerRow = a.row();
        headerRow.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout titleCol = a.vertical();
        TextView titleView = a.text(title, 18, Color.WHITE);
        titleView.setTypeface(null, Typeface.BOLD);
        titleCol.addView(titleView);
        if (subtitle != null && !subtitle.isEmpty()) {
            TextView subView = a.text(subtitle, 12.5f, MainActivity.MUTED);
            subView.setPadding(0, a.dp(4), 0, 0);
            titleCol.addView(subView);
        }
        headerRow.addView(titleCol, new LinearLayout.LayoutParams(0, -2, 1f));

        TextView closeBtn = a.text("关闭", 12.5f, 0xffe5e7eb);
        closeBtn.setGravity(Gravity.CENTER);
        closeBtn.setPadding(a.dp(13), a.dp(6), a.dp(13), a.dp(6));
        closeBtn.setBackground(a.bg(0x24ffffff, 999));
        bindTouchFeedback(closeBtn);
        closeBtn.setOnClickListener(v -> dlg.dismiss());
        headerRow.addView(closeBtn, new LinearLayout.LayoutParams(-2, -2));
        sheet.addView(headerRow, new LinearLayout.LayoutParams(-1, -2));

        a.gap(sheet, 16);

        int accent = a.mobileAccentColor();
        int accentFillTop = (accent & 0x00ffffff) | 0x38000000;
        int accentFillBot = (accent & 0x00ffffff) | 0x22000000;
        int accentStroke = (accent & 0x00ffffff) | 0x88000000;

        ScrollView scroll = new ScrollView(a);
        scroll.setVerticalScrollBarEnabled(false);
        LinearLayout list = a.vertical();
        for (int i = 0; i < options.length; i++) {
            final int idx = i;
            boolean active = (i == selectedIndex);
            LinearLayout optRow = a.row();
            optRow.setGravity(Gravity.CENTER_VERTICAL);
            optRow.setPadding(a.dp(16), a.dp(15), a.dp(16), a.dp(15));
            optRow.setBackground(
                    active
                            ? glassBg(
                                    accentFillTop, accentFillBot, a.dp(16), a.dp(1f), accentStroke)
                            : glassBg(0xb8202926, 0xb818201d, a.dp(16), a.dp(0.7f), 0x22ffffff));
            bindTouchFeedback(optRow);

            TextView label = a.text(options[i], 14.5f, active ? Color.WHITE : 0xffe5e7eb);
            label.setTypeface(null, active ? Typeface.BOLD : Typeface.NORMAL);
            optRow.addView(label, new LinearLayout.LayoutParams(0, -2, 1f));

            TextView check = a.text(active ? "✓" : "", 16, accent);
            check.setTypeface(null, Typeface.BOLD);
            optRow.addView(check, new LinearLayout.LayoutParams(-2, -2));

            optRow.setOnClickListener(
                    v -> {
                        dlg.dismiss();
                        if (onSelect != null) onSelect.accept(idx);
                    });

            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
            lp.bottomMargin = a.dp(10);
            list.addView(optRow, lp);
        }
        scroll.addView(list, new ScrollView.LayoutParams(-1, -2));
        int maxSheetHeight = Math.round(a.windowHeight() * 0.72f);
        sheet.addView(scroll, new LinearLayout.LayoutParams(-1, -2));

        FrameLayout.LayoutParams sheetLp =
                new FrameLayout.LayoutParams(
                        sheetWidth, -2, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        sheetLp.topMargin = Math.max(a.dp(80), a.windowHeight() - maxSheetHeight);
        backdrop.addView(sheet, sheetLp);

        dlg.setContentView(
                backdrop,
                new ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        dlg.show();
        if (dlg.getWindow() != null) {
            dlg.getWindow()
                    .setLayout(
                            WindowManager.LayoutParams.MATCH_PARENT,
                            WindowManager.LayoutParams.MATCH_PARENT);
            dlg.getWindow().setGravity(Gravity.BOTTOM | Gravity.FILL_HORIZONTAL);
        }
    }

    static void showMobileImportDialog(MainActivity a) {
        LinearLayout panel = a.vertical();
        panel.setPadding(a.dp(4), a.dp(6), a.dp(4), a.dp(4));

        TextView tip =
                a.text("输入或粘贴配置网址（JSON / JS / PY / TXT / M3U / ZIP）或源码文本：", 13, MainActivity.MUTED);
        panel.addView(tip);
        a.gap(panel, 10);

        final EditText input = new EditText(a);
        input.setHint("https://…/config.json 或 .js / .py / .txt / .zip");
        input.setHintTextColor(0xff6b7280);
        input.setTextColor(MainActivity.WHITE);
        input.setTextSize(14);
        input.setSingleLine(true);
        input.setShowSoftInputOnFocus(true);
        input.setLongClickable(true);
        input.setTextIsSelectable(true);
        input.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
        input.setBackground(a.bg(0xff1e2623, 12));
        String savedOrigin = a.prefs.getString(Prefs.ORIGIN, "");
        if (!savedOrigin.isEmpty()) {
            input.setText(savedOrigin);
            input.setSelection(savedOrigin.length());
        }
        panel.addView(input, new LinearLayout.LayoutParams(-1, -2));
        a.gap(panel, 12);

        int accent = a.mobileAccentColor();
        TextView pasteBtn = a.text("一键读取剪贴板并直接导入", 13, Color.WHITE);
        pasteBtn.setTypeface(null, Typeface.BOLD);
        pasteBtn.setGravity(Gravity.CENTER);
        pasteBtn.setPadding(a.dp(14), a.dp(11), a.dp(14), a.dp(11));
        pasteBtn.setBackground(a.bg(accent, 999));
        bindTouchFeedback(pasteBtn);
        panel.addView(pasteBtn, new LinearLayout.LayoutParams(-1, -2));
        a.gap(panel, 8);

        TextView fileBtn = a.text("选择本地配置或本地包 (.json/.js/.py/.txt/.zip)", 13, MainActivity.WHITE);
        fileBtn.setGravity(Gravity.CENTER);
        fileBtn.setPadding(a.dp(14), a.dp(11), a.dp(14), a.dp(11));
        fileBtn.setBackground(a.bg(0xff1e2623, 999));
        bindTouchFeedback(fileBtn);
        panel.addView(fileBtn, new LinearLayout.LayoutParams(-1, -2));
        a.gap(panel, 8);

        TextView liveBtn = a.text("导入或管理电视直播源 (M3U / TXT / JSON)", 13, MainActivity.WHITE);
        liveBtn.setGravity(Gravity.CENTER);
        liveBtn.setPadding(a.dp(14), a.dp(11), a.dp(14), a.dp(11));
        liveBtn.setBackground(a.bg(0xff1e2623, 999));
        bindTouchFeedback(liveBtn);
        panel.addView(liveBtn, new LinearLayout.LayoutParams(-1, -2));

        final AppDialog dialog =
                new AppDialog.Builder(a)
                        .setTitle("导入或更新配置")
                        .setView(panel)
                        .setNegativeButton("取消", null)
                        .setNeutralButton("连接 Emby", (d, w) -> EmbyEngine.connect(a))
                        .setPositiveButton(
                                "导入输入内容",
                                (d, w) -> {
                                    String raw = input.getText().toString().trim();
                                    if (raw.isEmpty()) {
                                        a.toast("请输入配置网址或点击剪贴板导入");
                                        return;
                                    }
                                    importTextOrUrl(a, raw);
                                })
                        .create();

        pasteBtn.setOnClickListener(
                v -> {
                    dialog.dismiss();
                    pasteConfigFromClipboard(a);
                });
        fileBtn.setOnClickListener(
                v -> {
                    dialog.dismiss();
                    a.pickConfig();
                });
        liveBtn.setOnClickListener(
                v -> {
                    dialog.dismiss();
                    SourceController.showLiveImportDialog(a);
                });
        dialog.show();
    }

    static void pasteConfigFromClipboard(MainActivity a) {
        ClipboardManager cm = (ClipboardManager) a.getSystemService(Context.CLIPBOARD_SERVICE);
        String text = "";
        if (cm != null && cm.hasPrimaryClip()) {
            ClipData clip = cm.getPrimaryClip();
            if (clip != null && clip.getItemCount() > 0 && clip.getItemAt(0).getText() != null) {
                text = clip.getItemAt(0).getText().toString().trim();
            }
        }
        if (text.isEmpty()) {
            a.toast("剪贴板为空，请先复制配置网址或源码内容");
            return;
        }
        importTextOrUrl(a, text);
    }

    static void importTextOrUrl(MainActivity a, String rawInput) {
        final String pasted = rawInput == null ? "" : rawInput.trim();
        if (pasted.isEmpty()) {
            a.toast("请输入有效的配置网址或源码内容");
            return;
        }
        a.toast("正在读取并解析配置…");
        a.worker.execute(
                () -> {
                    try {
                        String origin = a.configOrigin;
                        String rawJson = pasted;
                        if (Cms.isHttp(pasted)) {
                            origin = Cms.normalizeHttp(pasted);
                            String lowerOrigin = origin.toLowerCase(Locale.ROOT);
                            if (lowerOrigin.endsWith(".zip") || lowerOrigin.contains(".zip?")) {
                                HttpURLConnection conn =
                                        (HttpURLConnection) new URL(origin).openConnection();
                                conn.setConnectTimeout(15000);
                                conn.setReadTimeout(25000);
                                conn.setRequestProperty("User-Agent", Cms.USER_AGENT);
                                byte[] bytes;
                                try (InputStream in = conn.getInputStream();
                                        ByteArrayOutputStream bos = new ByteArrayOutputStream()) {
                                    byte[] buf = new byte[8192];
                                    int n;
                                    while ((n = in.read(buf)) != -1) {
                                        if (bos.size() + n > 28 * 1024 * 1024)
                                            throw new IOException("远程包超过 28 MB 限制");
                                        bos.write(buf, 0, n);
                                    }
                                    bytes = bos.toByteArray();
                                } finally {
                                    conn.disconnect();
                                }
                                LocalSourcePackage pkg =
                                        LocalSourcePackage.open(a.getFilesDir(), bytes);
                                a.ui.post(
                                        () -> {
                                            try {
                                                SourceController.applyLocalPackage(a, pkg);
                                            } catch (Exception ex) {
                                                a.toast("保存配置失败：" + a.message(ex));
                                            }
                                        });
                                return;
                            } else {
                                rawJson = SourceController.fetchImport(a, origin);
                                origin = SourceController.importOrigin(origin);
                            }
                        }
                        // Optional AI static safety check for imported Python scripts
                        if (!a.isTvDevice()
                                && rawJson != null
                                && (origin.toLowerCase(Locale.ROOT).endsWith(".py")
                                        || rawJson.contains("class Spider")
                                        || rawJson.contains("def homeContent"))) {
                            String warn = AiAssistantService.staticSafetyScanPython(rawJson);
                            if (warn != null && !warn.isEmpty()) {
                                a.ui.post(() -> a.toast("Python 脚本安全提醒：" + warn));
                            }
                        }
                        try {
                            Cms.Config parsed = Cms.parseConfig(rawJson, origin);
                            final String savedOrigin = origin;
                            a.ui.post(
                                    () -> {
                                        try {
                                            a.saveConfig(parsed, savedOrigin);
                                            a.toast("配置导入成功（共 " + parsed.sites.size() + " 个片源）");
                                        } catch (Exception ex) {
                                            a.toast("保存配置失败：" + a.message(ex));
                                        }
                                    });
                        } catch (Exception parseEx) {
                            String trimmed = rawJson == null ? "" : rawJson.trim();
                            if (trimmed.startsWith("#EXTM3U")
                                    || trimmed.contains("#genre#")
                                    || trimmed.contains(",http://")
                                    || trimmed.contains(",https://")
                                    || trimmed.contains(",rtmp://")
                                    || trimmed.contains(",rtsp://")) {
                                SourceController.importLiveTextOrUrl(a, pasted);
                                return;
                            }
                            throw parseEx;
                        }
                    } catch (Exception e) {
                        a.ui.post(() -> a.toast("配置读取失败：" + a.message(e)));
                    }
                });
    }

    /** iOS-style capsule toggle switch (`50dp × 30dp`, accent track + sliding white thumb). */
    static class IosSwitchView extends View {
        private final MainActivity a;
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private boolean checked;
        private float progress;
        private ValueAnimator animator;

        IosSwitchView(MainActivity activity, boolean initialChecked) {
            super(activity);
            this.a = activity;
            this.checked = initialChecked;
            this.progress = initialChecked ? 1f : 0f;
            setClickable(false);
            setFocusable(false);
        }

        boolean isChecked() {
            return checked;
        }

        void setChecked(boolean next, boolean animate) {
            this.checked = next;
            float target = next ? 1f : 0f;
            if (animator != null) {
                animator.cancel();
                animator = null;
            }
            if (!animate || Math.abs(progress - target) < 0.01f) {
                progress = target;
                invalidate();
                return;
            }
            animator = ValueAnimator.ofFloat(progress, target);
            animator.setDuration(160);
            animator.setInterpolator(new DecelerateInterpolator());
            animator.addUpdateListener(
                    anim -> {
                        progress = (Float) anim.getAnimatedValue();
                        invalidate();
                    });
            animator.start();
        }

        private static int blendColor(int c1, int c2, float ratio) {
            float r = Math.max(0f, Math.min(1f, ratio));
            int a1 = (c1 >>> 24) & 0xff,
                    r1 = (c1 >> 16) & 0xff,
                    g1 = (c1 >> 8) & 0xff,
                    b1 = c1 & 0xff;
            int a2 = (c2 >>> 24) & 0xff,
                    r2 = (c2 >> 16) & 0xff,
                    g2 = (c2 >> 8) & 0xff,
                    b2 = c2 & 0xff;
            int oa = Math.round(a1 + (a2 - a1) * r);
            int or = Math.round(r1 + (r2 - r1) * r);
            int og = Math.round(g1 + (g2 - g1) * r);
            int ob = Math.round(b1 + (b2 - b1) * r);
            return (oa << 24) | (or << 16) | (og << 8) | ob;
        }

        @Override
        protected void onDraw(Canvas c) {
            float w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            float radius = h / 2f;
            int onColor = a.isTvDevice() ? 0xff30d158 : a.mobileAccentColor();
            int trackColor = blendColor(0x58787880, onColor, progress);
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(trackColor);
            RectF trackRect = new RectF(0, 0, w, h);
            c.drawRoundRect(trackRect, radius, radius, paint);

            if (progress < 0.95f) {
                paint.setStyle(Paint.Style.STROKE);
                paint.setStrokeWidth(Math.max(1f, a.dp(0.8f)));
                paint.setColor(blendColor(0x2effffff, 0x00ffffff, progress));
                float inset = paint.getStrokeWidth() / 2f;
                c.drawRoundRect(
                        new RectF(inset, inset, w - inset, h - inset), radius, radius, paint);
            }

            float pad = a.dp(2f);
            float thumbRadius = (h - pad * 2f) / 2f;
            float minCx = pad + thumbRadius;
            float maxCx = w - pad - thumbRadius;
            float cx = minCx + (maxCx - minCx) * progress;
            float cy = h / 2f;

            paint.setStyle(Paint.Style.FILL);
            paint.setColor(0x33000000);
            c.drawCircle(cx, cy + a.dp(0.8f), thumbRadius, paint);

            paint.setColor(Color.WHITE);
            c.drawCircle(cx, cy, thumbRadius, paint);
        }
    }

    /** Semantic vector icon badge (`38dp × 38dp` rounded square + vector glyph). */
    static class SettingIconView extends View {
        static final int ICON_SOURCES = 1;
        static final int ICON_NETDISK = 2;
        static final int ICON_PLAYBACK = 3;
        static final int ICON_APPEARANCE = 4;
        static final int ICON_SYSTEM = 5;
        static final int ICON_CLIPBOARD = 11;
        static final int ICON_LINK_CODE = 12;
        static final int ICON_FOLDER_FILE = 13;
        static final int ICON_LIVE_TV = 14;
        static final int ICON_SWITCH_SOURCE = 15;
        static final int ICON_PLUGIN_EXT = 16;
        static final int ICON_ENGINE_CORE = 21;
        static final int ICON_DECODER_CHIP = 22;
        static final int ICON_HDR_TUNNEL = 23;
        static final int ICON_AUTO_NEXT = 24;
        static final int ICON_SKIP_TIMELINE = 25;
        static final int ICON_SUBTITLE = 26;
        static final int ICON_UI_SCALE = 31;
        static final int ICON_NAV_FONT = 32;
        static final int ICON_GLASS_BLUR = 33;
        static final int ICON_MOTION_SPARK = 34;
        static final int ICON_TRASH_CLEAR = 35;
        static final int ICON_UPDATE_CLOUD = 41;
        static final int ICON_DIAGNOSTIC_LOG = 42;
        static final int ICON_BACKUP_SAFE = 43;
        static final int ICON_WALLPAPER = 51;
        static final int ICON_GRID_COLS = 52;
        static final int ICON_AUDIO_WAVE = 53;
        static final int ICON_ASPECT_RATIO = 54;
        static final int ICON_SPEED_GAUGE = 55;
        static final int ICON_REPEAT_LOOP = 56;
        static final int ICON_AI_SPARKLE = 61;
        static final int ICON_TMDB_STAR = 62;
        static final int ICON_GESTURE_TOUCH = 63;

        private final MainActivity a;
        private final int kind;
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);

        SettingIconView(MainActivity activity, int kind) {
            super(activity);
            this.a = activity;
            this.kind = kind;
        }

        static int kindForSetting(String key, String title) {
            String k = key == null ? "" : key;
            String t = title == null ? "" : title;
            if (t.contains("AI") || t.contains("净化") || t.contains("大模型")) return ICON_AI_SPARKLE;
            if (t.contains("TMDB") || t.contains("刮削") || t.contains("评分") || t.contains("追剧"))
                return ICON_TMDB_STAR;
            if (t.contains("手势") || t.contains("亮度") || t.contains("双指")) return ICON_GESTURE_TOUCH;
            if (k.contains("settings-appearance")) return ICON_APPEARANCE;
            if (k.contains("settings-playback")) return ICON_PLAYBACK;
            if (k.contains("settings-data")) return ICON_SOURCES;
            if (k.contains("settings-updates")) return ICON_UPDATE_CLOUD;
            if (k.contains("settings-accounts") || t.contains("网盘") || t.contains("WebDAV"))
                return ICON_NETDISK;
            if (k.contains("settings-live-import") || t.contains("直播") || t.contains("电视"))
                return ICON_LIVE_TV;
            if (k.contains("settings-import") || t.contains("配置源")) return ICON_LINK_CODE;
            if (k.contains("settings-depots") || t.contains("线路") || t.contains("切换"))
                return ICON_SWITCH_SOURCE;
            if (k.contains(Prefs.EXPERIMENTAL_CSP) || t.contains("扩展") || t.contains("Python"))
                return ICON_PLUGIN_EXT;
            if (k.contains("settings-backup")
                    || k.contains("settings-restore")
                    || t.contains("备份")
                    || t.contains("还原")) return ICON_BACKUP_SAFE;
            if (k.contains("settings-logs") || t.contains("日志")) return ICON_DIAGNOSTIC_LOG;
            if (k.contains("clear-history") || t.contains("清除") || t.contains("清空"))
                return ICON_TRASH_CLEAR;
            if (k.contains("settings-history")
                    || k.contains("clear-images")
                    || k.contains("settings-reset")
                    || k.contains(Prefs.REPEAT_MODE)
                    || t.contains("循环")
                    || t.contains("历史")
                    || t.contains("恢复")) return ICON_REPEAT_LOOP;
            if (k.contains(Prefs.UI_SCALE_PERCENT) || t.contains("界面大小") || t.contains("缩放"))
                return ICON_UI_SCALE;
            if (k.contains(Prefs.NAV_SCALE_PERCENT) || t.contains("导航栏") || t.contains("底栏"))
                return ICON_NAV_FONT;
            if (k.contains(Prefs.HOME_COLUMNS) || t.contains("每行海报")) return ICON_GRID_COLS;
            if (k.contains("wallpaper")
                    || k.contains(Prefs.HOME_AMBIENT)
                    || t.contains("壁纸")
                    || t.contains("图片")
                    || t.contains("柔光")
                    || t.contains("压暗")) return ICON_WALLPAPER;
            if (k.contains(Prefs.REDUCED_TRANSPARENCY) || t.contains("透明") || t.contains("玻璃"))
                return ICON_GLASS_BLUR;
            if (k.contains(Prefs.REDUCED)
                    || k.contains(Prefs.STARTUP_ANIMATION)
                    || t.contains("动画")
                    || t.contains("动态")) return ICON_MOTION_SPARK;
            if (k.contains(Prefs.VIDEO_OUTPUT)
                    || k.contains(Prefs.TUNNELED_PLAYBACK)
                    || t.contains("HDR")
                    || t.contains("画面输出")) return ICON_HDR_TUNNEL;
            if (k.contains(Prefs.PLAYER_ENGINE) || t.contains("播放器") || t.contains("内核"))
                return ICON_ENGINE_CORE;
            if (k.contains(Prefs.DECODER_MODE) || k.contains("decoders") || t.contains("解码"))
                return ICON_DECODER_CHIP;
            if (k.contains(Prefs.SOFTWARE_AUDIO)
                    || k.contains(Prefs.PREFER_AAC)
                    || k.contains(Prefs.AUDIO_EFFECT)
                    || t.contains("音轨")
                    || t.contains("音效")
                    || t.contains("音频")
                    || t.contains("响度")) return ICON_AUDIO_WAVE;
            if (k.contains(Prefs.ASPECT)
                    || k.contains(Prefs.PICTURE_EFFECT)
                    || t.contains("画面比例")
                    || t.contains("色彩")) return ICON_ASPECT_RATIO;
            if (k.contains(Prefs.PLAY_SPEED)
                    || k.contains(Prefs.BUFFER_SECONDS)
                    || k.contains(Prefs.SEARCH_THREADS)
                    || k.contains(Prefs.SEARCH_TIMEOUT)
                    || t.contains("速度")
                    || t.contains("倍速")
                    || t.contains("缓冲")) return ICON_SPEED_GAUGE;
            if (k.contains(Prefs.AUTO_NEXT) || t.contains("下一集") || t.contains("连播"))
                return ICON_AUTO_NEXT;
            if (k.contains(Prefs.SKIP_INTRO) || k.contains(Prefs.SKIP_OUTRO) || t.contains("跳过片"))
                return ICON_SKIP_TIMELINE;
            if (k.contains(Prefs.SUBTITLE_SIZE)
                    || k.contains(Prefs.SUBTITLE_STYLE)
                    || k.contains(Prefs.DANMAKU_DEFAULT)
                    || t.contains("字幕")
                    || t.contains("弹幕")) return ICON_SUBTITLE;
            return ICON_SOURCES;
        }

        @Override
        protected void onDraw(Canvas c) {
            float w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            float cx = w / 2f, cy = h / 2f;
            int badgeBg;
            int strokeColor;
            switch (kind) {
                case ICON_SOURCES:
                case ICON_CLIPBOARD:
                case ICON_DECODER_CHIP:
                case ICON_GLASS_BLUR:
                    badgeBg = 0x2606b6d4;
                    strokeColor = 0xff22d3ee;
                    break;
                case ICON_NETDISK:
                case ICON_PLUGIN_EXT:
                case ICON_AUTO_NEXT:
                case ICON_REPEAT_LOOP:
                    badgeBg = 0x2610b981;
                    strokeColor = 0xff34d399;
                    break;
                case ICON_PLAYBACK:
                case ICON_ENGINE_CORE:
                case ICON_SPEED_GAUGE:
                case ICON_TMDB_STAR:
                    badgeBg = 0x26f59e0b;
                    strokeColor = 0xfffbbf24;
                    break;
                case ICON_FOLDER_FILE:
                case ICON_SKIP_TIMELINE:
                case ICON_GESTURE_TOUCH:
                    badgeBg = 0x26f97316;
                    strokeColor = 0xfffb923c;
                    break;
                case ICON_APPEARANCE:
                case ICON_HDR_TUNNEL:
                case ICON_UI_SCALE:
                case ICON_GRID_COLS:
                case ICON_AI_SPARKLE:
                    badgeBg = 0x26a855f7;
                    strokeColor = 0xffc084fc;
                    break;
                case ICON_NAV_FONT:
                    badgeBg = 0x26ec4899;
                    strokeColor = 0xfff472b6;
                    break;
                case ICON_LIVE_TV:
                case ICON_AUDIO_WAVE:
                    badgeBg = 0x26f43f5e;
                    strokeColor = 0xfffb7185;
                    break;
                case ICON_TRASH_CLEAR:
                    badgeBg = 0x26ef4444;
                    strokeColor = 0xfff87171;
                    break;
                case ICON_MOTION_SPARK:
                    badgeBg = 0x26eab308;
                    strokeColor = 0xfffacc15;
                    break;
                case ICON_DIAGNOSTIC_LOG:
                case ICON_WALLPAPER:
                    badgeBg = 0x2614b8a6;
                    strokeColor = 0xff2dd4bf;
                    break;
                case ICON_SWITCH_SOURCE:
                case ICON_BACKUP_SAFE:
                    badgeBg = 0x266366f1;
                    strokeColor = 0xff818cf8;
                    break;
                case ICON_SUBTITLE:
                case ICON_ASPECT_RATIO:
                    badgeBg = 0x260ea5e9;
                    strokeColor = 0xff38bdf8;
                    break;
                case ICON_SYSTEM:
                case ICON_LINK_CODE:
                case ICON_UPDATE_CLOUD:
                default:
                    badgeBg = 0x263b82f6;
                    strokeColor = 0xff60a5fa;
                    break;
            }
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(badgeBg);
            c.drawRoundRect(new RectF(0, 0, w, h), a.dp(10), a.dp(10), paint);

            paint.setStyle(Paint.Style.STROKE);
            paint.setColor(strokeColor);
            paint.setStrokeWidth(a.dp(1.65f));
            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setStrokeJoin(Paint.Join.ROUND);

            switch (kind) {
                case ICON_AI_SPARKLE:
                    {
                        Path star = new Path();
                        float rOut = a.dp(8.2f), rIn = a.dp(2.6f);
                        star.moveTo(cx, cy - rOut);
                        star.lineTo(cx + rIn, cy - rIn);
                        star.lineTo(cx + rOut, cy);
                        star.lineTo(cx + rIn, cy + rIn);
                        star.lineTo(cx, cy + rOut);
                        star.lineTo(cx - rIn, cy + rIn);
                        star.lineTo(cx - rOut, cy);
                        star.lineTo(cx - rIn, cy - rIn);
                        star.close();
                        c.drawPath(star, paint);
                        paint.setStyle(Paint.Style.FILL);
                        c.drawCircle(cx + a.dp(6.2f), cy - a.dp(6.2f), a.dp(1.3f), paint);
                        break;
                    }
                case ICON_TMDB_STAR:
                    {
                        RectF film =
                                new RectF(
                                        cx - a.dp(8.2f),
                                        cy - a.dp(6.5f),
                                        cx + a.dp(8.2f),
                                        cy + a.dp(6.5f));
                        c.drawRoundRect(film, a.dp(2.2f), a.dp(2.2f), paint);
                        c.drawCircle(cx, cy, a.dp(2.8f), paint);
                        c.drawLine(
                                cx - a.dp(5.2f),
                                cy - a.dp(6.5f),
                                cx - a.dp(5.2f),
                                cy + a.dp(6.5f),
                                paint);
                        c.drawLine(
                                cx + a.dp(5.2f),
                                cy - a.dp(6.5f),
                                cx + a.dp(5.2f),
                                cy + a.dp(6.5f),
                                paint);
                        break;
                    }
                case ICON_GESTURE_TOUCH:
                    {
                        c.drawCircle(cx, cy - a.dp(3.5f), a.dp(4.2f), paint);
                        c.drawLine(cx, cy - a.dp(1.2f), cx, cy + a.dp(7.5f), paint);
                        c.drawLine(
                                cx - a.dp(6.5f),
                                cy + a.dp(2.2f),
                                cx + a.dp(6.5f),
                                cy + a.dp(2.2f),
                                paint);
                        break;
                    }
                case ICON_SOURCES:
                    {
                        Path top = new Path();
                        top.moveTo(cx, cy - a.dp(8f));
                        top.lineTo(cx + a.dp(8f), cy - a.dp(3.2f));
                        top.lineTo(cx, cy + a.dp(1.6f));
                        top.lineTo(cx - a.dp(8f), cy - a.dp(3.2f));
                        top.close();
                        c.drawPath(top, paint);
                        c.drawLine(cx - a.dp(8f), cy + a.dp(0.8f), cx, cy + a.dp(5.2f), paint);
                        c.drawLine(cx + a.dp(8f), cy + a.dp(0.8f), cx, cy + a.dp(5.2f), paint);
                        c.drawLine(cx - a.dp(8f), cy + a.dp(4.4f), cx, cy + a.dp(8.8f), paint);
                        c.drawLine(cx + a.dp(8f), cy + a.dp(4.4f), cx, cy + a.dp(8.8f), paint);
                        break;
                    }
                case ICON_NETDISK:
                    {
                        RectF base =
                                new RectF(
                                        cx - a.dp(8.2f),
                                        cy - a.dp(1.5f),
                                        cx + a.dp(8.2f),
                                        cy + a.dp(6.8f));
                        c.drawRoundRect(base, a.dp(4.2f), a.dp(4.2f), paint);
                        c.drawArc(
                                new RectF(
                                        cx - a.dp(5.2f),
                                        cy - a.dp(7.5f),
                                        cx + a.dp(5.2f),
                                        cy + a.dp(2.5f)),
                                185,
                                170,
                                false,
                                paint);
                        c.drawLine(cx, cy + a.dp(4.2f), cx, cy - a.dp(1.2f), paint);
                        c.drawLine(cx - a.dp(2.3f), cy + a.dp(1f), cx, cy - a.dp(1.4f), paint);
                        c.drawLine(cx + a.dp(2.3f), cy + a.dp(1f), cx, cy - a.dp(1.4f), paint);
                        break;
                    }
                case ICON_PLAYBACK:
                case ICON_ENGINE_CORE:
                    {
                        RectF scr =
                                new RectF(
                                        cx - a.dp(8.5f),
                                        cy - a.dp(6.5f),
                                        cx + a.dp(8.5f),
                                        cy + a.dp(6.5f));
                        c.drawRoundRect(scr, a.dp(2.8f), a.dp(2.8f), paint);
                        paint.setStyle(Paint.Style.FILL);
                        Path tri = new Path();
                        tri.moveTo(cx - a.dp(2.2f), cy - a.dp(3.2f));
                        tri.lineTo(cx + a.dp(3.4f), cy);
                        tri.lineTo(cx - a.dp(2.2f), cy + a.dp(3.2f));
                        tri.close();
                        c.drawPath(tri, paint);
                        break;
                    }
                case ICON_APPEARANCE:
                    {
                        float x1 = cx - a.dp(8f), x2 = cx + a.dp(8f);
                        c.drawLine(x1, cy - a.dp(4.5f), x2, cy - a.dp(4.5f), paint);
                        c.drawLine(x1, cy + a.dp(4.5f), x2, cy + a.dp(4.5f), paint);
                        paint.setStyle(Paint.Style.FILL);
                        c.drawCircle(cx - a.dp(2.8f), cy - a.dp(4.5f), a.dp(2.4f), paint);
                        c.drawCircle(cx + a.dp(2.8f), cy + a.dp(4.5f), a.dp(2.4f), paint);
                        break;
                    }
                case ICON_CLIPBOARD:
                    {
                        RectF board =
                                new RectF(
                                        cx - a.dp(6.8f),
                                        cy - a.dp(6.2f),
                                        cx + a.dp(6.8f),
                                        cy + a.dp(8.2f));
                        c.drawRoundRect(board, a.dp(2.2f), a.dp(2.2f), paint);
                        RectF clip =
                                new RectF(
                                        cx - a.dp(3.2f),
                                        cy - a.dp(8.4f),
                                        cx + a.dp(3.2f),
                                        cy - a.dp(4.8f));
                        paint.setStyle(Paint.Style.FILL);
                        c.drawRoundRect(clip, a.dp(1.4f), a.dp(1.4f), paint);
                        paint.setStyle(Paint.Style.STROKE);
                        c.drawLine(
                                cx - a.dp(3.6f),
                                cy - a.dp(0.8f),
                                cx + a.dp(3.6f),
                                cy - a.dp(0.8f),
                                paint);
                        c.drawLine(
                                cx - a.dp(3.6f),
                                cy + a.dp(3.4f),
                                cx + a.dp(2.2f),
                                cy + a.dp(3.4f),
                                paint);
                        break;
                    }
                case ICON_LINK_CODE:
                    {
                        c.drawLine(cx - a.dp(3.8f), cy - a.dp(4.5f), cx - a.dp(8.2f), cy, paint);
                        c.drawLine(cx - a.dp(8.2f), cy, cx - a.dp(3.8f), cy + a.dp(4.5f), paint);
                        c.drawLine(cx + a.dp(3.8f), cy - a.dp(4.5f), cx + a.dp(8.2f), cy, paint);
                        c.drawLine(cx + a.dp(8.2f), cy, cx + a.dp(3.8f), cy + a.dp(4.5f), paint);
                        c.drawLine(
                                cx + a.dp(1.8f),
                                cy - a.dp(6.2f),
                                cx - a.dp(1.8f),
                                cy + a.dp(6.2f),
                                paint);
                        break;
                    }
                case ICON_FOLDER_FILE:
                    {
                        Path folder = new Path();
                        folder.moveTo(cx - a.dp(8.2f), cy - a.dp(6.8f));
                        folder.lineTo(cx - a.dp(2.2f), cy - a.dp(6.8f));
                        folder.lineTo(cx + a.dp(0.2f), cy - a.dp(4.2f));
                        folder.lineTo(cx + a.dp(8.2f), cy - a.dp(4.2f));
                        folder.lineTo(cx + a.dp(8.2f), cy + a.dp(7.2f));
                        folder.lineTo(cx - a.dp(8.2f), cy + a.dp(7.2f));
                        folder.close();
                        c.drawPath(folder, paint);
                        c.drawLine(
                                cx - a.dp(8f),
                                cy - a.dp(0.8f),
                                cx + a.dp(8f),
                                cy - a.dp(0.8f),
                                paint);
                        break;
                    }
                case ICON_LIVE_TV:
                    {
                        RectF tv =
                                new RectF(
                                        cx - a.dp(8f),
                                        cy - a.dp(3.8f),
                                        cx + a.dp(8f),
                                        cy + a.dp(7.5f));
                        c.drawRoundRect(tv, a.dp(2.4f), a.dp(2.4f), paint);
                        c.drawLine(cx - a.dp(4.5f), cy - a.dp(8.5f), cx, cy - a.dp(3.8f), paint);
                        c.drawLine(cx + a.dp(4.5f), cy - a.dp(8.5f), cx, cy - a.dp(3.8f), paint);
                        paint.setStyle(Paint.Style.FILL);
                        c.drawCircle(cx, cy + a.dp(1.8f), a.dp(2f), paint);
                        break;
                    }
                case ICON_SWITCH_SOURCE:
                    {
                        float lx = cx - a.dp(7.5f), rx = cx + a.dp(7.5f);
                        float ty = cy - a.dp(3.5f), by = cy + a.dp(3.5f);
                        c.drawLine(lx, ty, rx, ty, paint);
                        c.drawLine(rx - a.dp(3f), ty - a.dp(2.6f), rx, ty, paint);
                        c.drawLine(rx - a.dp(3f), ty + a.dp(2.6f), rx, ty, paint);
                        c.drawLine(rx, by, lx, by, paint);
                        c.drawLine(lx + a.dp(3f), by - a.dp(2.6f), lx, by, paint);
                        c.drawLine(lx + a.dp(3f), by + a.dp(2.6f), lx, by, paint);
                        break;
                    }
                case ICON_PLUGIN_EXT:
                    {
                        float s = a.dp(5.6f), g = a.dp(1.4f);
                        c.drawRoundRect(
                                new RectF(cx - g - s, cy - g - s, cx - g, cy - g),
                                a.dp(1.5f),
                                a.dp(1.5f),
                                paint);
                        c.drawRoundRect(
                                new RectF(cx - g - s, cy + g, cx - g, cy + g + s),
                                a.dp(1.5f),
                                a.dp(1.5f),
                                paint);
                        c.drawRoundRect(
                                new RectF(cx + g, cy + g, cx + g + s, cy + g + s),
                                a.dp(1.5f),
                                a.dp(1.5f),
                                paint);
                        paint.setStyle(Paint.Style.FILL);
                        c.drawRoundRect(
                                new RectF(
                                        cx + g + a.dp(0.8f),
                                        cy - g - s - a.dp(0.8f),
                                        cx + g + s + a.dp(0.8f),
                                        cy - g - a.dp(0.8f)),
                                a.dp(1.5f),
                                a.dp(1.5f),
                                paint);
                        break;
                    }
                case ICON_DECODER_CHIP:
                    {
                        RectF chip =
                                new RectF(
                                        cx - a.dp(5.5f),
                                        cy - a.dp(5.5f),
                                        cx + a.dp(5.5f),
                                        cy + a.dp(5.5f));
                        c.drawRoundRect(chip, a.dp(1.8f), a.dp(1.8f), paint);
                        float p = a.dp(2.4f), in = a.dp(5.5f), out = a.dp(8.5f);
                        c.drawLine(cx - p, cy - out, cx - p, cy - in, paint);
                        c.drawLine(cx + p, cy - out, cx + p, cy - in, paint);
                        c.drawLine(cx - p, cy + in, cx - p, cy + out, paint);
                        c.drawLine(cx + p, cy + in, cx + p, cy + out, paint);
                        c.drawLine(cx - out, cy - p, cx - in, cy - p, paint);
                        c.drawLine(cx - out, cy + p, cx - in, cy + p, paint);
                        c.drawLine(cx + in, cy - p, cx + out, cy - p, paint);
                        c.drawLine(cx + in, cy + p, cx + out, cy + p, paint);
                        paint.setStyle(Paint.Style.FILL);
                        c.drawRoundRect(
                                new RectF(
                                        cx - a.dp(2.2f),
                                        cy - a.dp(2.2f),
                                        cx + a.dp(2.2f),
                                        cy + a.dp(2.2f)),
                                a.dp(0.8f),
                                a.dp(0.8f),
                                paint);
                        break;
                    }
                case ICON_HDR_TUNNEL:
                    {
                        RectF scr =
                                new RectF(
                                        cx - a.dp(8.5f),
                                        cy - a.dp(6.5f),
                                        cx + a.dp(8.5f),
                                        cy + a.dp(6.5f));
                        c.drawRoundRect(scr, a.dp(2.5f), a.dp(2.5f), paint);
                        c.drawCircle(cx, cy, a.dp(2.4f), paint);
                        c.drawLine(cx, cy - a.dp(4.6f), cx, cy - a.dp(3.8f), paint);
                        c.drawLine(cx, cy + a.dp(3.8f), cx, cy + a.dp(4.6f), paint);
                        c.drawLine(cx - a.dp(4.8f), cy, cx - a.dp(3.8f), cy, paint);
                        c.drawLine(cx + a.dp(3.8f), cy, cx + a.dp(4.8f), cy, paint);
                        break;
                    }
                case ICON_AUTO_NEXT:
                    {
                        paint.setStyle(Paint.Style.FILL);
                        Path t1 = new Path();
                        t1.moveTo(cx - a.dp(7.5f), cy - a.dp(4.5f));
                        t1.lineTo(cx - a.dp(1.2f), cy);
                        t1.lineTo(cx - a.dp(7.5f), cy + a.dp(4.5f));
                        t1.close();
                        c.drawPath(t1, paint);
                        Path t2 = new Path();
                        t2.moveTo(cx - a.dp(1.2f), cy - a.dp(4.5f));
                        t2.lineTo(cx + a.dp(5.2f), cy);
                        t2.lineTo(cx - a.dp(1.2f), cy + a.dp(4.5f));
                        t2.close();
                        c.drawPath(t2, paint);
                        paint.setStyle(Paint.Style.STROKE);
                        c.drawLine(
                                cx + a.dp(6.8f),
                                cy - a.dp(4.5f),
                                cx + a.dp(6.8f),
                                cy + a.dp(4.5f),
                                paint);
                        break;
                    }
                case ICON_SKIP_TIMELINE:
                    {
                        c.drawLine(
                                cx - a.dp(8f), cy + a.dp(5f), cx + a.dp(8f), cy + a.dp(5f), paint);
                        c.drawArc(
                                new RectF(
                                        cx - a.dp(6.5f),
                                        cy - a.dp(6.5f),
                                        cx + a.dp(6.5f),
                                        cy + a.dp(3.5f)),
                                195,
                                150,
                                false,
                                paint);
                        break;
                    }
                case ICON_SUBTITLE:
                    {
                        RectF box =
                                new RectF(
                                        cx - a.dp(8.5f),
                                        cy - a.dp(6.5f),
                                        cx + a.dp(8.5f),
                                        cy + a.dp(6.5f));
                        c.drawRoundRect(box, a.dp(2.5f), a.dp(2.5f), paint);
                        c.drawLine(
                                cx - a.dp(5.2f),
                                cy + a.dp(0.5f),
                                cx + a.dp(5.2f),
                                cy + a.dp(0.5f),
                                paint);
                        c.drawLine(
                                cx - a.dp(3.6f),
                                cy + a.dp(3.5f),
                                cx + a.dp(3.6f),
                                cy + a.dp(3.5f),
                                paint);
                        break;
                    }
                case ICON_UI_SCALE:
                    {
                        float d = a.dp(7.5f), s = a.dp(3.4f);
                        c.drawLine(cx - d, cy - d, cx - d + s, cy - d, paint);
                        c.drawLine(cx - d, cy - d, cx - d, cy - d + s, paint);
                        c.drawLine(cx + d, cy - d, cx + d - s, cy - d, paint);
                        c.drawLine(cx + d, cy - d, cx + d, cy - d + s, paint);
                        c.drawLine(cx - d, cy + d, cx - d + s, cy + d, paint);
                        c.drawLine(cx - d, cy + d, cx - d, cy + d - s, paint);
                        c.drawLine(cx + d, cy + d, cx + d - s, cy + d, paint);
                        c.drawLine(cx + d, cy + d, cx + d, cy + d - s, paint);
                        break;
                    }
                case ICON_NAV_FONT:
                    {
                        c.drawLine(
                                cx - a.dp(3.5f),
                                cy - a.dp(6.5f),
                                cx - a.dp(7.2f),
                                cy + a.dp(3f),
                                paint);
                        c.drawLine(
                                cx - a.dp(3.5f),
                                cy - a.dp(6.5f),
                                cx + a.dp(0.2f),
                                cy + a.dp(3f),
                                paint);
                        c.drawCircle(cx + a.dp(4.8f), cy + a.dp(0.2f), a.dp(2.6f), paint);
                        c.drawLine(
                                cx - a.dp(7.5f),
                                cy + a.dp(7f),
                                cx + a.dp(7.5f),
                                cy + a.dp(7f),
                                paint);
                        break;
                    }
                case ICON_GLASS_BLUR:
                    {
                        c.drawCircle(cx - a.dp(2.6f), cy - a.dp(2.2f), a.dp(5.4f), paint);
                        paint.setAlpha(110);
                        paint.setStyle(Paint.Style.FILL);
                        c.drawCircle(cx + a.dp(2.8f), cy + a.dp(2.4f), a.dp(5.4f), paint);
                        paint.setAlpha(255);
                        paint.setStyle(Paint.Style.STROKE);
                        c.drawCircle(cx + a.dp(2.8f), cy + a.dp(2.4f), a.dp(5.4f), paint);
                        break;
                    }
                case ICON_MOTION_SPARK:
                    {
                        Path bolt = new Path();
                        bolt.moveTo(cx + a.dp(1.2f), cy - a.dp(8.2f));
                        bolt.lineTo(cx - a.dp(5.2f), cy + a.dp(0.6f));
                        bolt.lineTo(cx + a.dp(0.2f), cy + a.dp(0.6f));
                        bolt.lineTo(cx - a.dp(1.2f), cy + a.dp(8.2f));
                        bolt.lineTo(cx + a.dp(5.2f), cy - a.dp(0.6f));
                        bolt.lineTo(cx - a.dp(0.2f), cy - a.dp(0.6f));
                        bolt.close();
                        c.drawPath(bolt, paint);
                        break;
                    }
                case ICON_TRASH_CLEAR:
                    {
                        c.drawLine(
                                cx - a.dp(7.2f),
                                cy - a.dp(5.2f),
                                cx + a.dp(7.2f),
                                cy - a.dp(5.2f),
                                paint);
                        RectF bin =
                                new RectF(
                                        cx - a.dp(5.2f),
                                        cy - a.dp(5.2f),
                                        cx + a.dp(5.2f),
                                        cy + a.dp(7.8f));
                        c.drawRoundRect(bin, a.dp(1.8f), a.dp(1.8f), paint);
                        break;
                    }
                case ICON_DIAGNOSTIC_LOG:
                    {
                        RectF box =
                                new RectF(
                                        cx - a.dp(8.5f),
                                        cy - a.dp(6.8f),
                                        cx + a.dp(8.5f),
                                        cy + a.dp(6.8f));
                        c.drawRoundRect(box, a.dp(2.4f), a.dp(2.4f), paint);
                        Path pulse = new Path();
                        pulse.moveTo(cx - a.dp(5.8f), cy + a.dp(0.5f));
                        pulse.lineTo(cx - a.dp(2.6f), cy + a.dp(0.5f));
                        pulse.lineTo(cx - a.dp(1f), cy - a.dp(3.8f));
                        pulse.lineTo(cx + a.dp(1.2f), cy + a.dp(3.8f));
                        pulse.lineTo(cx + a.dp(2.8f), cy + a.dp(0.5f));
                        pulse.lineTo(cx + a.dp(5.8f), cy + a.dp(0.5f));
                        c.drawPath(pulse, paint);
                        break;
                    }
                case ICON_BACKUP_SAFE:
                    {
                        RectF lid =
                                new RectF(
                                        cx - a.dp(8.2f),
                                        cy - a.dp(6.5f),
                                        cx + a.dp(8.2f),
                                        cy - a.dp(2.2f));
                        c.drawRoundRect(lid, a.dp(1.5f), a.dp(1.5f), paint);
                        RectF body =
                                new RectF(
                                        cx - a.dp(7f),
                                        cy - a.dp(2.2f),
                                        cx + a.dp(7f),
                                        cy + a.dp(7.5f));
                        c.drawRoundRect(body, a.dp(2f), a.dp(2f), paint);
                        break;
                    }
                case ICON_WALLPAPER:
                    {
                        RectF frame =
                                new RectF(
                                        cx - a.dp(8.5f),
                                        cy - a.dp(6.5f),
                                        cx + a.dp(8.5f),
                                        cy + a.dp(6.5f));
                        c.drawRoundRect(frame, a.dp(2.4f), a.dp(2.4f), paint);
                        Path mtn = new Path();
                        mtn.moveTo(cx - a.dp(6.5f), cy + a.dp(5.2f));
                        mtn.lineTo(cx - a.dp(1.5f), cy + a.dp(0.2f));
                        mtn.lineTo(cx + a.dp(1.8f), cy + a.dp(3.2f));
                        mtn.lineTo(cx + a.dp(6.8f), cy + a.dp(5.2f));
                        c.drawPath(mtn, paint);
                        break;
                    }
                case ICON_GRID_COLS:
                    {
                        float s = a.dp(5.8f), g = a.dp(1.4f);
                        c.drawRoundRect(
                                new RectF(cx - g - s, cy - g - s, cx - g, cy - g),
                                a.dp(1.4f),
                                a.dp(1.4f),
                                paint);
                        c.drawRoundRect(
                                new RectF(cx + g, cy - g - s, cx + g + s, cy - g),
                                a.dp(1.4f),
                                a.dp(1.4f),
                                paint);
                        c.drawRoundRect(
                                new RectF(cx - g - s, cy + g, cx - g, cy + g + s),
                                a.dp(1.4f),
                                a.dp(1.4f),
                                paint);
                        c.drawRoundRect(
                                new RectF(cx + g, cy + g, cx + g + s, cy + g + s),
                                a.dp(1.4f),
                                a.dp(1.4f),
                                paint);
                        break;
                    }
                case ICON_AUDIO_WAVE:
                    {
                        c.drawLine(
                                cx - a.dp(6.8f),
                                cy - a.dp(3f),
                                cx - a.dp(6.8f),
                                cy + a.dp(3f),
                                paint);
                        c.drawLine(
                                cx - a.dp(3.4f),
                                cy - a.dp(7f),
                                cx - a.dp(3.4f),
                                cy + a.dp(7f),
                                paint);
                        c.drawLine(cx, cy - a.dp(4.5f), cx, cy + a.dp(4.5f), paint);
                        c.drawLine(
                                cx + a.dp(3.4f),
                                cy - a.dp(8f),
                                cx + a.dp(3.4f),
                                cy + a.dp(8f),
                                paint);
                        c.drawLine(
                                cx + a.dp(6.8f),
                                cy - a.dp(3.5f),
                                cx + a.dp(6.8f),
                                cy + a.dp(3.5f),
                                paint);
                        break;
                    }
                case ICON_ASPECT_RATIO:
                    {
                        RectF frame =
                                new RectF(
                                        cx - a.dp(8.8f),
                                        cy - a.dp(6f),
                                        cx + a.dp(8.8f),
                                        cy + a.dp(6f));
                        c.drawRoundRect(frame, a.dp(2.2f), a.dp(2.2f), paint);
                        break;
                    }
                case ICON_SPEED_GAUGE:
                    {
                        c.drawArc(
                                new RectF(
                                        cx - a.dp(8f),
                                        cy - a.dp(6.5f),
                                        cx + a.dp(8f),
                                        cy + a.dp(9.5f)),
                                155,
                                230,
                                false,
                                paint);
                        c.drawLine(cx, cy + a.dp(2f), cx + a.dp(4.2f), cy - a.dp(3.2f), paint);
                        break;
                    }
                case ICON_REPEAT_LOOP:
                    {
                        c.drawArc(
                                new RectF(
                                        cx - a.dp(7.5f),
                                        cy - a.dp(7.5f),
                                        cx + a.dp(7.5f),
                                        cy + a.dp(7.5f)),
                                -45,
                                290,
                                false,
                                paint);
                        c.drawLine(cx, cy - a.dp(3.5f), cx, cy + a.dp(0.5f), paint);
                        c.drawLine(cx, cy + a.dp(0.5f), cx + a.dp(2.8f), cy + a.dp(2.2f), paint);
                        break;
                    }
                case ICON_SYSTEM:
                case ICON_UPDATE_CLOUD:
                default:
                    {
                        c.drawArc(
                                new RectF(a.dp(9.5f), a.dp(9.5f), w - a.dp(9.5f), h - a.dp(9.5f)),
                                -30,
                                300,
                                false,
                                paint);
                        c.drawLine(cx, a.dp(13f), cx, cy + a.dp(3.5f), paint);
                        c.drawLine(cx - a.dp(2.8f), cy + a.dp(0.8f), cx, cy + a.dp(3.6f), paint);
                        c.drawLine(cx + a.dp(2.8f), cy + a.dp(0.8f), cx, cy + a.dp(3.6f), paint);
                        break;
                    }
            }
        }
    }
}
