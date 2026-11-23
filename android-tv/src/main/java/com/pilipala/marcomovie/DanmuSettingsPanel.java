// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.app.AlertDialog;
import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.InputType;
import android.text.TextUtils;
import android.util.DisplayMetrics;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import com.pilipala.marcomovie.DanmuProvider.BlockFilter;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

/**
 * Self-contained Android danmu preferences store and Apple TV / iOS frosted-glass settings modal.
 *
 * <p>Persists exclusively under {@code danmu_*} keys in {@link SharedPreferences} without touching
 * {@code Prefs.java}. Default server URL list is strictly empty ({@code ""}).
 */
public final class DanmuSettingsPanel {

    public static final String PREFS_FILE = "movie";
    public static final String KEY_ENABLED = "danmu_enabled";
    public static final String KEY_SERVER_URLS = "danmu_server_urls";
    public static final String KEY_APP_ID = "danmu_app_id";
    public static final String KEY_APP_SECRET = "danmu_app_secret";
    public static final String KEY_OPACITY = "danmu_opacity";
    public static final String KEY_DISPLAY_AREA = "danmu_display_area";
    public static final String KEY_FONT_SIZE = "danmu_font_size";
    public static final String KEY_SPEED_MULTIPLIER = "danmu_speed_multiplier";
    public static final String KEY_TIME_OFFSET_MS = "danmu_time_offset_ms";
    public static final String KEY_SHOW_SCROLL = "danmu_show_scroll";
    public static final String KEY_SHOW_TOP = "danmu_show_top";
    public static final String KEY_SHOW_BOTTOM = "danmu_show_bottom";
    public static final String KEY_MAX_ROWS = "danmu_max_rows";
    public static final String KEY_BLOCK_RULES = "danmu_block_rules";

    public static final float DEFAULT_OPACITY = 0.85f;
    public static final float DEFAULT_DISPLAY_AREA = 0.50f;
    public static final float DEFAULT_MOBILE_FONT_SIZE = 20f;
    public static final float DEFAULT_TV_FONT_SIZE = 24f;
    public static final float DEFAULT_SPEED_MULTIPLIER = 1.0f;
    public static final long DEFAULT_TIME_OFFSET_MS = 0L;
    public static final int DEFAULT_MOBILE_MAX_ROWS = 14;
    public static final int DEFAULT_TV_MAX_ROWS = 6;
    public static final float[] AREA_OPTIONS = new float[] {0.25f, 0.50f, 0.75f, 1.00f};
    public static final float[] SPEED_OPTIONS = new float[] {0.75f, 1.00f, 1.25f, 1.50f};

    public static final int[] TV_ROW_PRESETS = new int[] {3, 5, 6, 8};
    public static final int[] MOBILE_ROW_PRESETS = new int[] {4, 6, 10, 14};
    public static final float[] TV_FONT_PRESETS = new float[] {20f, 24f, 28f, 32f};
    public static final float[] MOBILE_FONT_PRESETS = new float[] {16f, 20f, 24f, 28f};
    public static final float[] OPACITY_PRESETS = new float[] {0.40f, 0.65f, 0.85f, 1.00f};
    public static final String[] FONT_PRESET_LABELS = new String[] {"小", "标准", "大", "特大"};
    public static final String[] SPEED_PRESET_LABELS = new String[] {"慢", "标准", "较快", "快"};
    public static final String[] AREA_PRESET_LABELS = new String[] {"1/4屏", "半屏", "3/4屏", "全屏"};

    private static final int COLOR_MODAL_BG = 0xFA131822;
    private static final int COLOR_MODAL_OPAQUE = 0xFF151B24;
    private static final int COLOR_CARD_BG = 0x14FFFFFF;
    private static final int COLOR_CARD_STROKE = 0x22FFFFFF;
    private static final int COLOR_TRACK_BG = 0x36000000;
    private static final int COLOR_TRACK_STROKE = 0x1CFFFFFF;
    private static final int COLOR_DIVIDER = 0x1AFFFFFF;
    private static final int COLOR_ACCENT = 0xFF0A84FF;
    private static final int COLOR_ACCENT_SOFT = 0x240A84FF;
    private static final int COLOR_ACCENT_TEXT = 0xFF7AC0FF;
    private static final int COLOR_GREEN = 0xFF30D158;
    private static final int COLOR_GREEN_SOFT = 0x2B30D158;
    private static final int COLOR_GREEN_STROKE = 0x6630D158;
    private static final int COLOR_FOCUS_FILL = 0xFFF5F5F7;
    private static final int COLOR_FOCUS_TEXT = 0xFF101013;
    private static final int COLOR_TEXT_PRIMARY = 0xFFF5F5F7;
    private static final int COLOR_TEXT_SECONDARY = 0xFF9EA9B8;
    private static final int COLOR_PILL_IDLE = 0x1AFFFFFF;
    private static final int COLOR_PILL_IDLE_TEXT = 0xFFD8E0EA;

    public interface OnConfigChangedListener {
        void onDanmuConfigChanged(DanmuConfig config);
    }

    public static final class DanmuConfig {
        public final boolean enabled;
        public final String serverUrls;
        public final String appId;
        public final String appSecret;
        public final float opacity;
        public final float displayArea;
        public final float fontSizeSp;
        public final float speedMultiplier;
        public final long timeOffsetMs;
        public final boolean showScroll;
        public final boolean showTop;
        public final boolean showBottom;
        public final int maxRows;
        public final List<String> blockRules;
        public final boolean tvProfile;

        public DanmuConfig(
                boolean enabled,
                String serverUrls,
                String appId,
                String appSecret,
                float opacity,
                float displayArea,
                float fontSizeSp,
                float speedMultiplier,
                long timeOffsetMs,
                boolean showScroll,
                boolean showTop,
                boolean showBottom,
                int maxRows,
                List<String> blockRules,
                boolean tvProfile) {
            this.tvProfile = tvProfile;
            this.enabled = enabled;
            this.serverUrls = serverUrls == null ? "" : serverUrls.trim();
            this.appId = appId == null ? "" : appId.trim();
            this.appSecret = appSecret == null ? "" : appSecret.trim();
            this.opacity = clampOpacity(opacity);
            this.displayArea = snapArea(displayArea);
            this.fontSizeSp = clampFontSize(fontSizeSp, tvProfile);
            this.speedMultiplier = snapSpeed(speedMultiplier);
            this.timeOffsetMs = clampTimeOffsetMs(timeOffsetMs);
            this.showScroll = showScroll;
            this.showTop = showTop;
            this.showBottom = showBottom;
            this.maxRows = clampMaxRows(maxRows, tvProfile);
            this.blockRules = sanitizeBlockRules(blockRules);
        }

        public static DanmuConfig defaults(boolean isTv) {
            return new DanmuConfig(
                    false,
                    DandanplayProvider.DEFAULT_SERVER_URLS,
                    "",
                    "",
                    DEFAULT_OPACITY,
                    DEFAULT_DISPLAY_AREA,
                    isTv ? DEFAULT_TV_FONT_SIZE : DEFAULT_MOBILE_FONT_SIZE,
                    DEFAULT_SPEED_MULTIPLIER,
                    DEFAULT_TIME_OFFSET_MS,
                    true,
                    true,
                    true,
                    isTv ? DEFAULT_TV_MAX_ROWS : DEFAULT_MOBILE_MAX_ROWS,
                    Collections.<String>emptyList(),
                    isTv);
        }

        public DandanplayProvider createProvider() {
            return new DandanplayProvider(serverUrls, appId, appSecret);
        }

        public BlockFilter createBlockFilter() {
            return BlockFilter.compile(blockRules);
        }

        public Builder toBuilder() {
            return new Builder(this);
        }

        public static final class Builder {
            boolean enabled;
            String serverUrls;
            String appId;
            String appSecret;
            float opacity;
            float displayArea;
            float fontSizeSp;
            float speedMultiplier;
            long timeOffsetMs;
            boolean showScroll;
            boolean showTop;
            boolean showBottom;
            int maxRows;
            List<String> blockRules;
            boolean tvProfile;

            Builder(DanmuConfig src) {
                this.enabled = src.enabled;
                this.serverUrls = src.serverUrls;
                this.appId = src.appId;
                this.appSecret = src.appSecret;
                this.opacity = src.opacity;
                this.displayArea = src.displayArea;
                this.fontSizeSp = src.fontSizeSp;
                this.speedMultiplier = src.speedMultiplier;
                this.timeOffsetMs = src.timeOffsetMs;
                this.showScroll = src.showScroll;
                this.showTop = src.showTop;
                this.showBottom = src.showBottom;
                this.maxRows = src.maxRows;
                this.blockRules = new ArrayList<>(src.blockRules);
                this.tvProfile = src.tvProfile;
            }

            public DanmuConfig build() {
                return new DanmuConfig(
                        enabled,
                        serverUrls,
                        appId,
                        appSecret,
                        opacity,
                        displayArea,
                        fontSizeSp,
                        speedMultiplier,
                        timeOffsetMs,
                        showScroll,
                        showTop,
                        showBottom,
                        maxRows,
                        blockRules,
                        tvProfile);
            }
        }
    }

    private DanmuSettingsPanel() {}

    public static int[] rowPresets(boolean isTv) {
        int[] src = isTv ? TV_ROW_PRESETS : MOBILE_ROW_PRESETS;
        int[] copy = new int[src.length];
        System.arraycopy(src, 0, copy, 0, src.length);
        return copy;
    }

    public static float[] fontSizePresets(boolean isTv) {
        float[] src = isTv ? TV_FONT_PRESETS : MOBILE_FONT_PRESETS;
        float[] copy = new float[src.length];
        System.arraycopy(src, 0, copy, 0, src.length);
        return copy;
    }

    public static float[] opacityPresets() {
        float[] copy = new float[OPACITY_PRESETS.length];
        System.arraycopy(OPACITY_PRESETS, 0, copy, 0, OPACITY_PRESETS.length);
        return copy;
    }

    public static DanmuConfig resetDisplayDefaults(DanmuConfig current) {
        if (current == null) return DanmuConfig.defaults(false);
        DanmuConfig def = DanmuConfig.defaults(current.tvProfile);
        DanmuConfig.Builder b = current.toBuilder();
        b.opacity = def.opacity;
        b.displayArea = def.displayArea;
        b.fontSizeSp = def.fontSizeSp;
        b.speedMultiplier = def.speedMultiplier;
        b.timeOffsetMs = def.timeOffsetMs;
        b.showScroll = def.showScroll;
        b.showTop = def.showTop;
        b.showBottom = def.showBottom;
        b.maxRows = def.maxRows;
        return b.build();
    }

    public static String formatAreaShort(float area) {
        float snapped = snapArea(area);
        for (int i = 0; i < AREA_OPTIONS.length && i < AREA_PRESET_LABELS.length; i++) {
            if (Math.abs(snapped - AREA_OPTIONS[i]) < 0.01f) {
                return AREA_PRESET_LABELS[i];
            }
        }
        return Math.round(snapped * 100f) + "%";
    }

    public static String formatSpeedShort(float mult) {
        float snapped = snapSpeed(mult);
        if (Math.abs(snapped - 1.0f) < 0.01f) return "1.0x";
        if (Math.abs(snapped - 1.5f) < 0.01f) return "1.5x";
        return String.format(Locale.US, "%.2fx", snapped);
    }

    public static String formatOffsetShort(long offsetMs) {
        if (offsetMs == 0L) return "0.0s";
        return String.format(Locale.US, "%+.1fs", offsetMs / 1000.0);
    }

    public static String formatCompactStatus(DanmuConfig config) {
        if (config == null) return "";
        return config.maxRows
                + "行 · "
                + Math.round(config.fontSizeSp)
                + "sp · "
                + formatSpeedShort(config.speedMultiplier)
                + " · "
                + formatAreaShort(config.displayArea);
    }

    public static String formatConfigSummary(DanmuConfig config) {
        if (config == null) return "已关闭";
        int serverCount = config.createProvider().getConfiguredOrigins().size();
        StringBuilder sb = new StringBuilder();
        sb.append(config.enabled ? "已开启" : "已关闭");
        sb.append(" · ").append(formatCompactStatus(config));
        if (serverCount > 0) {
            sb.append(" · ").append(serverCount).append("个源");
        }
        return sb.toString();
    }

    public static float clampOpacity(float value) {
        float clamped = Math.max(0.20f, Math.min(1.00f, value));
        return Math.round(clamped * 20f) / 20f;
    }

    public static float snapArea(float value) {
        float best = AREA_OPTIONS[1];
        float bestDiff = Float.MAX_VALUE;
        for (float opt : AREA_OPTIONS) {
            float diff = Math.abs(opt - value);
            if (diff < bestDiff) {
                bestDiff = diff;
                best = opt;
            }
        }
        return best;
    }

    public static float clampFontSize(float sp, boolean isTv) {
        float min = isTv ? 18f : 14f;
        float max = isTv ? 36f : 32f;
        return Math.max(min, Math.min(max, Math.round(sp)));
    }

    public static float snapSpeed(float value) {
        float best = SPEED_OPTIONS[1];
        float bestDiff = Float.MAX_VALUE;
        for (float opt : SPEED_OPTIONS) {
            float diff = Math.abs(opt - value);
            if (diff < bestDiff) {
                bestDiff = diff;
                best = opt;
            }
        }
        return best;
    }

    public static long clampTimeOffsetMs(long offsetMs) {
        long clamped = Math.max(-30000L, Math.min(30000L, offsetMs));
        return Math.round(clamped / 500.0) * 500L;
    }

    public static int clampMaxRows(int rows, boolean isTv) {
        int cap = isTv ? 8 : 14;
        return Math.max(2, Math.min(cap, rows));
    }

    public static List<String> sanitizeBlockRules(List<String> rawRules) {
        if (rawRules == null || rawRules.isEmpty()) return Collections.emptyList();
        List<String> out = new ArrayList<>();
        for (String rule : rawRules) {
            if (out.size() >= BlockFilter.MAX_RULES) break;
            if (rule == null) continue;
            String trimmed = rule.trim();
            if (trimmed.isEmpty()) continue;
            if (BlockFilter.validateRule(trimmed).valid && !out.contains(trimmed)) {
                out.add(trimmed);
            }
        }
        return Collections.unmodifiableList(out);
    }

    public static DanmuConfig loadConfig(Context context, boolean isTv) {
        if (context == null) return DanmuConfig.defaults(isTv);
        SharedPreferences prefs = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE);
        DanmuConfig def = DanmuConfig.defaults(isTv);
        String rawRules = prefs.getString(KEY_BLOCK_RULES, "");
        List<String> rules = new ArrayList<>();
        if (rawRules != null && !rawRules.trim().isEmpty()) {
            for (String line : rawRules.split("\\r?\\n")) {
                if (!line.trim().isEmpty()) rules.add(line.trim());
            }
        }
        return new DanmuConfig(
                prefs.getBoolean(KEY_ENABLED, def.enabled),
                prefs.getString(KEY_SERVER_URLS, def.serverUrls),
                prefs.getString(KEY_APP_ID, def.appId),
                prefs.getString(KEY_APP_SECRET, def.appSecret),
                prefs.getFloat(KEY_OPACITY, def.opacity),
                prefs.getFloat(KEY_DISPLAY_AREA, def.displayArea),
                prefs.getFloat(KEY_FONT_SIZE, def.fontSizeSp),
                prefs.getFloat(KEY_SPEED_MULTIPLIER, def.speedMultiplier),
                prefs.getLong(KEY_TIME_OFFSET_MS, def.timeOffsetMs),
                prefs.getBoolean(KEY_SHOW_SCROLL, def.showScroll),
                prefs.getBoolean(KEY_SHOW_TOP, def.showTop),
                prefs.getBoolean(KEY_SHOW_BOTTOM, def.showBottom),
                prefs.getInt(KEY_MAX_ROWS, def.maxRows),
                rules,
                isTv);
    }

    public static void saveConfig(Context context, DanmuConfig config) {
        if (context == null || config == null) return;
        SharedPreferences prefs = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE);
        StringBuilder rulesJoined = new StringBuilder();
        for (int i = 0; i < config.blockRules.size(); i++) {
            if (i > 0) rulesJoined.append('\n');
            rulesJoined.append(config.blockRules.get(i));
        }
        prefs.edit()
                .putBoolean(KEY_ENABLED, config.enabled)
                .putString(KEY_SERVER_URLS, config.serverUrls)
                .putString(KEY_APP_ID, config.appId)
                .putString(KEY_APP_SECRET, config.appSecret)
                .putFloat(KEY_OPACITY, config.opacity)
                .putFloat(KEY_DISPLAY_AREA, config.displayArea)
                .putFloat(KEY_FONT_SIZE, config.fontSizeSp)
                .putFloat(KEY_SPEED_MULTIPLIER, config.speedMultiplier)
                .putLong(KEY_TIME_OFFSET_MS, config.timeOffsetMs)
                .putBoolean(KEY_SHOW_SCROLL, config.showScroll)
                .putBoolean(KEY_SHOW_TOP, config.showTop)
                .putBoolean(KEY_SHOW_BOTTOM, config.showBottom)
                .putInt(KEY_MAX_ROWS, config.maxRows)
                .putString(KEY_BLOCK_RULES, rulesJoined.toString())
                .apply();
    }

    public static AlertDialog showDialog(
            Context context, boolean isTv, OnConfigChangedListener listener) {
        DisplayMetrics dm = context.getResources().getDisplayMetrics();
        int winW = dm.widthPixels;
        int winH = dm.heightPixels;
        if (context instanceof MainActivity) {
            MainActivity ma = (MainActivity) context;
            if (ma.windowWidth() > 0) winW = ma.windowWidth();
            if (ma.windowHeight() > 0) winH = ma.windowHeight();
        }
        final float d = dm.density;
        final int targetW =
                Math.min(
                        Math.round((isTv ? 700f : 432f) * d),
                        Math.max(
                                Math.round((isTv ? 460f : 300f) * d),
                                winW - Math.round((isTv ? 84f : 28f) * d)));
        final int maxDialogH =
                Math.max(Math.round(240f * d), Math.round(winH * (isTv ? 0.90f : 0.86f)));
        final int maxBodyH =
                Math.max(Math.round(160f * d), maxDialogH - Math.round((isTv ? 80f : 138f) * d));
        final AlertDialog[] dialogRef = new AlertDialog[1];
        final View[] initialFocusRef = new View[1];
        final View panel =
                buildPanelView(
                        context,
                        isTv,
                        listener,
                        new Runnable() {
                            @Override
                            public void run() {
                                if (dialogRef[0] != null) dialogRef[0].dismiss();
                            }
                        },
                        initialFocusRef,
                        maxBodyH);
        FrameLayout bounded =
                new FrameLayout(context) {
                    @Override
                    protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
                        int capped =
                                View.MeasureSpec.makeMeasureSpec(
                                        maxDialogH, View.MeasureSpec.AT_MOST);
                        super.onMeasure(widthMeasureSpec, capped);
                    }
                };
        bounded.setClipChildren(false);
        bounded.setClipToPadding(false);
        bounded.addView(
                panel,
                new FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        AlertDialog dialog =
                new AlertDialog.Builder(context, R.style.MarcoAlertDialogTheme)
                        .setView(bounded)
                        .create();
        dialogRef[0] = dialog;
        dialog.show();
        if (dialog.getWindow() != null) {
            Window win = dialog.getWindow();
            win.getDecorView().setTag("app-dialog");
            win.getDecorView().setMinimumWidth(0);
            win.getDecorView().setPadding(0, 0, 0, 0);
            win.setBackgroundDrawableResource(android.R.color.transparent);
            win.setDimAmount(isTv ? 0.48f : 0.54f);
            win.setLayout(targetW, WindowManager.LayoutParams.WRAP_CONTENT);
            win.setGravity(Gravity.CENTER);
        }
        if (isTv && initialFocusRef[0] != null) {
            final View target = initialFocusRef[0];
            target.post(
                    new Runnable() {
                        @Override
                        public void run() {
                            target.requestFocus();
                        }
                    });
        }
        return dialog;
    }

    public static View createPanelView(
            final Context context, final boolean isTv, final OnConfigChangedListener listener) {
        return buildPanelView(context, isTv, listener, null, new View[1], 0);
    }

    private static View buildPanelView(
            final Context context,
            final boolean isTv,
            final OnConfigChangedListener listener,
            final Runnable onClose,
            final View[] initialFocusOut,
            final int maxScrollHeightPx) {
        final DanmuConfig[] state = new DanmuConfig[] {loadConfig(context, isTv)};
        final int[] activeTab = new int[] {0};
        final float d = context.getResources().getDisplayMetrics().density;
        final SharedPreferences prefs =
                context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE);
        final boolean reducedMotion = prefs.getBoolean(Prefs.REDUCED, false);
        final boolean reducedTransparency = prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);

        LinearLayout shell = new LinearLayout(context);
        shell.setOrientation(LinearLayout.VERTICAL);
        shell.setClipChildren(false);
        shell.setClipToPadding(false);
        UiCompat.setBackground(
                shell,
                roundedShape(
                        reducedTransparency ? COLOR_MODAL_OPAQUE : COLOR_MODAL_BG,
                        24f * d,
                        0x30FFFFFF,
                        Math.max(1, dp(d, 1))));
        int hPad = dp(d, isTv ? 18 : 16);
        int topPad = dp(d, isTv ? 12 : 14);
        int bottomPad = dp(d, isTv ? 12 : 14);
        shell.setPadding(hPad, topPad, hPad, bottomPad);

        // ----- Header Chrome (Title + Live Summary + Tab Switcher + Reset / Done) -----
        final TextView summaryLine = new TextView(context);
        summaryLine.setTextColor(COLOR_TEXT_SECONDARY);
        summaryLine.setTextSize(TypedValue.COMPLEX_UNIT_SP, isTv ? 12f : 11.5f);
        summaryLine.setSingleLine(true);
        summaryLine.setEllipsize(TextUtils.TruncateAt.END);

        final TextView tabDisplay =
                makePill(context, "显示样式", d, isTv, reducedMotion, PillStyle.SEGMENT);
        final TextView tabAdvanced =
                makePill(context, "源与屏蔽", d, isTv, reducedMotion, PillStyle.SEGMENT);
        final TextView resetBtn =
                makePill(context, "恢复默认", d, isTv, reducedMotion, PillStyle.SUBTLE);
        final TextView doneBtn =
                onClose != null
                        ? makePill(context, "完成", d, isTv, reducedMotion, PillStyle.SUBTLE)
                        : null;

        LinearLayout tabTrack = makeSegmentTrack(context, d);
        LinearLayout.LayoutParams tabLp =
                new LinearLayout.LayoutParams(
                        isTv ? ViewGroup.LayoutParams.WRAP_CONTENT : 0,
                        dp(d, isTv ? 32 : 34),
                        isTv ? 0f : 1f);
        tabDisplay.setPadding(dp(d, 14), 0, dp(d, 14), 0);
        tabAdvanced.setPadding(dp(d, 14), 0, dp(d, 14), 0);
        tabTrack.addView(tabDisplay, tabLp);
        tabTrack.addView(tabAdvanced, new LinearLayout.LayoutParams(tabLp));

        LinearLayout titleCol = new LinearLayout(context);
        titleCol.setOrientation(LinearLayout.VERTICAL);
        TextView titleView = new TextView(context);
        titleView.setText("弹幕设置");
        titleView.setTextColor(COLOR_TEXT_PRIMARY);
        titleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, isTv ? 19f : 18f);
        titleView.setTypeface(null, Typeface.BOLD);
        titleView.setSingleLine(true);
        titleCol.addView(titleView);
        LinearLayout.LayoutParams sumLp =
                new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        sumLp.topMargin = dp(d, 2);
        titleCol.addView(summaryLine, sumLp);

        LinearLayout headerTop = new LinearLayout(context);
        headerTop.setOrientation(LinearLayout.HORIZONTAL);
        headerTop.setGravity(Gravity.CENTER_VERTICAL);
        headerTop.setClipChildren(false);
        headerTop.setClipToPadding(false);
        headerTop.addView(
                titleCol,
                new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        if (isTv) {
            LinearLayout.LayoutParams trackLp =
                    new LinearLayout.LayoutParams(
                            ViewGroup.LayoutParams.WRAP_CONTENT,
                            ViewGroup.LayoutParams.WRAP_CONTENT);
            trackLp.leftMargin = dp(d, 10);
            headerTop.addView(tabTrack, trackLp);
        }

        LinearLayout.LayoutParams actionLp =
                new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(d, 34));
        actionLp.leftMargin = dp(d, 8);
        resetBtn.setPadding(dp(d, 12), 0, dp(d, 12), 0);
        headerTop.addView(resetBtn, actionLp);
        if (doneBtn != null) {
            LinearLayout.LayoutParams doneLp =
                    new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(d, 34));
            doneLp.leftMargin = dp(d, 6);
            doneBtn.setPadding(dp(d, 14), 0, dp(d, 14), 0);
            headerTop.addView(doneBtn, doneLp);
            doneBtn.setOnClickListener(
                    new View.OnClickListener() {
                        @Override
                        public void onClick(View v) {
                            onClose.run();
                        }
                    });
        }
        shell.addView(headerTop);

        if (!isTv) {
            LinearLayout.LayoutParams mobileTabLp =
                    new LinearLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.WRAP_CONTENT);
            mobileTabLp.topMargin = dp(d, 10);
            shell.addView(tabTrack, mobileTabLp);
        }

        // Subtle divider between fixed header and body
        View headerDivider = new View(context);
        headerDivider.setBackgroundColor(COLOR_DIVIDER);
        LinearLayout.LayoutParams hdLp =
                new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1);
        hdLp.topMargin = dp(d, isTv ? 8 : 10);
        hdLp.bottomMargin = dp(d, isTv ? 8 : 10);
        shell.addView(headerDivider, hdLp);

        // ----- Scrollable Body Container -----
        final ScrollView scroll =
                new ScrollView(context) {
                    @Override
                    protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
                        int capped =
                                maxScrollHeightPx > 0
                                        ? View.MeasureSpec.makeMeasureSpec(
                                                maxScrollHeightPx, View.MeasureSpec.AT_MOST)
                                        : heightMeasureSpec;
                        super.onMeasure(widthMeasureSpec, capped);
                    }
                };
        scroll.setVerticalScrollBarEnabled(false);
        scroll.setClipChildren(false);
        scroll.setClipToPadding(false);
        scroll.setPadding(dp(d, 2), dp(d, 2), dp(d, 2), dp(d, 2));
        scroll.setOverScrollMode(View.OVER_SCROLL_NEVER);
        shell.addView(
                scroll,
                new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        FrameLayout bodyStack = new FrameLayout(context);
        bodyStack.setClipChildren(false);
        bodyStack.setClipToPadding(false);
        scroll.addView(
                bodyStack,
                new FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        // =========================================================================
        // TAB 0: 显示样式 (Clean, 1-screen Apple TV appearance controls)
        // =========================================================================
        final LinearLayout displayPane = new LinearLayout(context);
        displayPane.setOrientation(LinearLayout.VERTICAL);
        displayPane.setClipChildren(false);
        displayPane.setClipToPadding(false);

        // Master Toggle Banner
        LinearLayout masterCard = makeGlassCard(context, d, 16f);
        masterCard.setOrientation(LinearLayout.HORIZONTAL);
        masterCard.setGravity(Gravity.CENTER_VERTICAL);
        masterCard.setPadding(dp(d, 14), dp(d, isTv ? 7 : 9), dp(d, 12), dp(d, isTv ? 7 : 9));

        LinearLayout masterTextCol = new LinearLayout(context);
        masterTextCol.setOrientation(LinearLayout.VERTICAL);
        TextView masterTitle = new TextView(context);
        masterTitle.setText("显示弹幕");
        masterTitle.setTextColor(COLOR_TEXT_PRIMARY);
        masterTitle.setTextSize(TypedValue.COMPLEX_UNIT_SP, isTv ? 14.5f : 14.5f);
        masterTitle.setTypeface(null, Typeface.BOLD);
        TextView masterSub = new TextView(context);
        masterSub.setText("调整行数、字号、速度与透明度后立即生效");
        masterSub.setTextColor(COLOR_TEXT_SECONDARY);
        masterSub.setTextSize(TypedValue.COMPLEX_UNIT_SP, isTv ? 11.5f : 11.5f);
        masterSub.setSingleLine(true);
        masterSub.setEllipsize(TextUtils.TruncateAt.END);
        masterTextCol.addView(masterTitle);
        masterTextCol.addView(masterSub);
        masterCard.addView(
                masterTextCol,
                new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        final TextView masterToggle =
                makePill(context, "已关闭", d, isTv, reducedMotion, PillStyle.SWITCH);
        masterToggle.setMinWidth(dp(d, 86));
        masterToggle.setPadding(dp(d, 14), 0, dp(d, 14), 0);
        LinearLayout.LayoutParams toggleLp =
                new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.WRAP_CONTENT, dp(d, isTv ? 30 : 34));
        toggleLp.leftMargin = dp(d, 10);
        masterCard.addView(masterToggle, toggleLp);
        if (initialFocusOut != null && initialFocusOut.length > 0) {
            initialFocusOut[0] = masterToggle;
        }
        LinearLayout.LayoutParams masterCardLp =
                new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        masterCardLp.bottomMargin = dp(d, isTv ? 8 : 10);
        displayPane.addView(masterCard, masterCardLp);

        // Grouped Appearance Controls Card
        final LinearLayout controlsCard = makeGlassCard(context, d, 18f);
        controlsCard.setOrientation(LinearLayout.VERTICAL);
        controlsCard.setPadding(0, dp(d, 2), 0, dp(d, 2));

        final int[] rowPresetValues = rowPresets(isTv);
        final float[] fontPresetValues = fontSizePresets(isTv);
        final float[] opacityPresetValues = opacityPresets();

        final TextView rowsBadge = makeValueBadge(context, d);
        final TextView fontBadge = makeValueBadge(context, d);
        final TextView speedBadge = makeValueBadge(context, d);
        final TextView opacityBadge = makeValueBadge(context, d);
        final TextView areaBadge = makeValueBadge(context, d);
        final TextView offsetBadge = makeValueBadge(context, d);

        final TextView[] rowPills = new TextView[rowPresetValues.length];
        final TextView[] fontPills = new TextView[fontPresetValues.length];
        final TextView[] speedPills = new TextView[SPEED_OPTIONS.length];
        final TextView[] opacityPills = new TextView[opacityPresetValues.length];
        final TextView[] areaPills = new TextView[AREA_OPTIONS.length];
        final TextView scrollChip = makePill(context, "滚动", d, isTv, reducedMotion, PillStyle.CHIP);
        final TextView topChip = makePill(context, "顶部", d, isTv, reducedMotion, PillStyle.CHIP);
        final TextView bottomChip = makePill(context, "底部", d, isTv, reducedMotion, PillStyle.CHIP);
        final TextView offsetMinus =
                makePill(context, "-0.5s", d, isTv, reducedMotion, PillStyle.SEGMENT);
        final TextView offsetReset =
                makePill(context, "归零", d, isTv, reducedMotion, PillStyle.SEGMENT);
        final TextView offsetPlus =
                makePill(context, "+0.5s", d, isTv, reducedMotion, PillStyle.SEGMENT);

        // 1. 显示行数 (maxRows)
        LinearLayout rowTrack = makeSegmentTrack(context, d);
        for (int i = 0; i < rowPresetValues.length; i++) {
            final int rows = rowPresetValues[i];
            TextView pill =
                    makePill(context, rows + "行", d, isTv, reducedMotion, PillStyle.SEGMENT);
            rowPills[i] = pill;
            addSegmentPill(rowTrack, pill, d, isTv);
        }
        addControlRow(controlsCard, context, "显示行数", rowsBadge, rowTrack, d, isTv, false);

        // 2. 字体大小 (fontSizeSp)
        LinearLayout fontTrack = makeSegmentTrack(context, d);
        for (int i = 0; i < fontPresetValues.length; i++) {
            String label =
                    i < FONT_PRESET_LABELS.length
                            ? FONT_PRESET_LABELS[i]
                            : Math.round(fontPresetValues[i]) + "sp";
            TextView pill = makePill(context, label, d, isTv, reducedMotion, PillStyle.SEGMENT);
            fontPills[i] = pill;
            addSegmentPill(fontTrack, pill, d, isTv);
        }
        addControlRow(controlsCard, context, "字体大小", fontBadge, fontTrack, d, isTv, true);

        // 3. 移动速度 (speedMultiplier)
        LinearLayout speedTrack = makeSegmentTrack(context, d);
        for (int i = 0; i < SPEED_OPTIONS.length; i++) {
            String label =
                    i < SPEED_PRESET_LABELS.length
                            ? SPEED_PRESET_LABELS[i]
                            : formatSpeedShort(SPEED_OPTIONS[i]);
            TextView pill = makePill(context, label, d, isTv, reducedMotion, PillStyle.SEGMENT);
            speedPills[i] = pill;
            addSegmentPill(speedTrack, pill, d, isTv);
        }
        addControlRow(controlsCard, context, "移动速度", speedBadge, speedTrack, d, isTv, true);

        // 4. 不透明度 (opacity)
        LinearLayout opacityTrack = makeSegmentTrack(context, d);
        for (int i = 0; i < opacityPresetValues.length; i++) {
            String label = Math.round(opacityPresetValues[i] * 100f) + "%";
            TextView pill = makePill(context, label, d, isTv, reducedMotion, PillStyle.SEGMENT);
            opacityPills[i] = pill;
            addSegmentPill(opacityTrack, pill, d, isTv);
        }
        addControlRow(controlsCard, context, "不透明度", opacityBadge, opacityTrack, d, isTv, true);

        // 5. 显示区域 (displayArea)
        LinearLayout areaTrack = makeSegmentTrack(context, d);
        for (int i = 0; i < AREA_OPTIONS.length; i++) {
            String label =
                    i < AREA_PRESET_LABELS.length
                            ? AREA_PRESET_LABELS[i]
                            : Math.round(AREA_OPTIONS[i] * 100f) + "%";
            TextView pill = makePill(context, label, d, isTv, reducedMotion, PillStyle.SEGMENT);
            areaPills[i] = pill;
            addSegmentPill(areaTrack, pill, d, isTv);
        }
        addControlRow(controlsCard, context, "显示区域", areaBadge, areaTrack, d, isTv, true);

        // 6. 显示位置 (滚动 / 顶部 / 底部)
        LinearLayout posRow = new LinearLayout(context);
        posRow.setOrientation(LinearLayout.HORIZONTAL);
        posRow.setGravity(Gravity.CENTER_VERTICAL);
        posRow.setClipChildren(false);
        posRow.setClipToPadding(false);
        addChip(posRow, scrollChip, d, isTv, true);
        addChip(posRow, topChip, d, isTv, true);
        addChip(posRow, bottomChip, d, isTv, false);
        addControlRow(controlsCard, context, "显示位置", null, posRow, d, isTv, true);

        // 7. 时间校准 (timeOffsetMs)
        LinearLayout offsetTrack = makeSegmentTrack(context, d);
        addSegmentPill(offsetTrack, offsetMinus, d, isTv);
        addSegmentPill(offsetTrack, offsetReset, d, isTv);
        addSegmentPill(offsetTrack, offsetPlus, d, isTv);
        addControlRow(controlsCard, context, "时间校准", offsetBadge, offsetTrack, d, isTv, true);

        displayPane.addView(controlsCard);
        bodyStack.addView(
                displayPane,
                new FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        // =========================================================================
        // TAB 1: 源与屏蔽 (Custom Danmu API Servers + Keyword/Regex Blocklist)
        // =========================================================================
        final LinearLayout advancedPane = new LinearLayout(context);
        advancedPane.setOrientation(LinearLayout.VERTICAL);
        advancedPane.setClipChildren(false);
        advancedPane.setClipToPadding(false);
        advancedPane.setVisibility(View.GONE);

        MainActivity hostActivity = context instanceof MainActivity ? (MainActivity) context : null;

        // Card A: Custom Server Sources
        LinearLayout serverCard = makeGlassCard(context, d, 18f);
        serverCard.setOrientation(LinearLayout.VERTICAL);
        serverCard.setPadding(dp(d, 14), dp(d, 12), dp(d, 14), dp(d, 12));

        final TextView serverBadge = makeValueBadge(context, d);
        serverCard.addView(makeCardHeader(context, "自定义兼容弹幕服务", serverBadge, d));
        serverCard.addView(makeCardCaption(context, "每行填写一个 HTTP / HTTPS 地址（最多 8 个），默认留空", d));

        final EditText serverUrlsInput =
                makeInput(context, state[0].serverUrls, "https://danmu.example", true, d);
        LinearLayout.LayoutParams urlsLp =
                new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        urlsLp.topMargin = dp(d, 6);
        serverCard.addView(
                hostActivity != null
                        ? TvQrInputHelper.wrap(
                                hostActivity, serverUrlsInput, "弹幕服务地址", true, false, false, null)
                        : serverUrlsInput,
                urlsLp);

        serverCard.addView(makeCardCaption(context, "可选 Open API 凭据（AppId / AppSecret，可留空）", d));

        final EditText appIdInput = makeInput(context, state[0].appId, "AppId（可选）", false, d);
        final EditText appSecretInput =
                makeInput(context, state[0].appSecret, "AppSecret（可选）", false, d);
        appSecretInput.setInputType(
                InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        View wrappedAppId =
                hostActivity != null
                        ? TvQrInputHelper.wrap(hostActivity, appIdInput, "弹幕 AppId")
                        : appIdInput;
        View wrappedAppSecret =
                hostActivity != null
                        ? TvQrInputHelper.wrap(
                                hostActivity,
                                appSecretInput,
                                "弹幕 AppSecret",
                                false,
                                true,
                                false,
                                null)
                        : appSecretInput;

        LinearLayout credContainer = new LinearLayout(context);
        credContainer.setOrientation(isTv ? LinearLayout.HORIZONTAL : LinearLayout.VERTICAL);
        credContainer.setClipChildren(false);
        credContainer.setClipToPadding(false);
        LinearLayout.LayoutParams credWrapLp =
                new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        credWrapLp.topMargin = dp(d, 6);
        if (isTv) {
            LinearLayout.LayoutParams leftLp =
                    new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
            leftLp.rightMargin = dp(d, 8);
            credContainer.addView(wrappedAppId, leftLp);
            credContainer.addView(
                    wrappedAppSecret,
                    new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        } else {
            LinearLayout.LayoutParams firstLp =
                    new LinearLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.WRAP_CONTENT);
            firstLp.bottomMargin = dp(d, 8);
            credContainer.addView(wrappedAppId, firstLp);
            credContainer.addView(
                    wrappedAppSecret,
                    new LinearLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.WRAP_CONTENT));
        }
        serverCard.addView(credContainer, credWrapLp);

        LinearLayout serverFooter = new LinearLayout(context);
        serverFooter.setOrientation(LinearLayout.HORIZONTAL);
        serverFooter.setGravity(Gravity.CENTER_VERTICAL);
        serverFooter.setClipChildren(false);
        serverFooter.setClipToPadding(false);
        LinearLayout.LayoutParams sfLp =
                new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        sfLp.topMargin = dp(d, 10);
        TextView saveServerBtn =
                makePill(context, "保存服务配置", d, isTv, reducedMotion, PillStyle.PRIMARY);
        saveServerBtn.setPadding(dp(d, 16), 0, dp(d, 16), 0);
        serverFooter.addView(
                saveServerBtn,
                new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(d, 34)));
        final TextView serverFeedback = new TextView(context);
        serverFeedback.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f);
        serverFeedback.setTextColor(COLOR_GREEN);
        serverFeedback.setVisibility(View.GONE);
        LinearLayout.LayoutParams fbLp =
                new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        fbLp.leftMargin = dp(d, 10);
        serverFooter.addView(serverFeedback, fbLp);
        serverCard.addView(serverFooter, sfLp);

        LinearLayout.LayoutParams serverCardLp =
                new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        serverCardLp.bottomMargin = dp(d, 10);
        advancedPane.addView(serverCard, serverCardLp);

        // Card B: Keyword & Regex Blocklist
        LinearLayout blockCard = makeGlassCard(context, d, 18f);
        blockCard.setOrientation(LinearLayout.VERTICAL);
        blockCard.setPadding(dp(d, 14), dp(d, 12), dp(d, 14), dp(d, 12));

        final TextView rulesBadge = makeValueBadge(context, d);
        blockCard.addView(makeCardHeader(context, "屏蔽词管理", rulesBadge, d));
        blockCard.addView(makeCardCaption(context, "支持普通关键词或 re: 正则表达式，最多 100 条", d));

        final EditText ruleInput = makeInput(context, "", "输入关键词或 re:剧透|打卡", false, d);
        LinearLayout.LayoutParams ruleInputLp =
                new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        ruleInputLp.topMargin = dp(d, 6);
        blockCard.addView(
                hostActivity != null
                        ? TvQrInputHelper.wrap(hostActivity, ruleInput, "弹幕屏蔽规则")
                        : ruleInput,
                ruleInputLp);

        final TextView ruleError = new TextView(context);
        ruleError.setTextColor(0xFFFF6961);
        ruleError.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f);
        ruleError.setVisibility(View.GONE);
        LinearLayout.LayoutParams errLp =
                new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        errLp.topMargin = dp(d, 4);
        blockCard.addView(ruleError, errLp);

        LinearLayout ruleActions = new LinearLayout(context);
        ruleActions.setOrientation(LinearLayout.HORIZONTAL);
        ruleActions.setGravity(Gravity.CENTER_VERTICAL);
        ruleActions.setClipChildren(false);
        ruleActions.setClipToPadding(false);
        LinearLayout.LayoutParams raLp =
                new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        raLp.topMargin = dp(d, 8);
        TextView addRuleBtn =
                makePill(context, "添加屏蔽规则", d, isTv, reducedMotion, PillStyle.PRIMARY);
        addRuleBtn.setPadding(dp(d, 14), 0, dp(d, 14), 0);
        TextView clearRulesBtn =
                makePill(context, "清空规则", d, isTv, reducedMotion, PillStyle.SUBTLE);
        clearRulesBtn.setPadding(dp(d, 14), 0, dp(d, 14), 0);
        ruleActions.addView(
                addRuleBtn,
                new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(d, 34)));
        LinearLayout.LayoutParams clrLp =
                new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(d, 34));
        clrLp.leftMargin = dp(d, 8);
        ruleActions.addView(clearRulesBtn, clrLp);
        blockCard.addView(ruleActions, raLp);

        final TextView rulesSummary = new TextView(context);
        rulesSummary.setTextColor(COLOR_TEXT_SECONDARY);
        rulesSummary.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f);
        LinearLayout.LayoutParams rsLp =
                new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        rsLp.topMargin = dp(d, 8);
        blockCard.addView(rulesSummary, rsLp);

        advancedPane.addView(blockCard);
        bodyStack.addView(
                advancedPane,
                new FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        // =========================================================================
        // State Refresh & Wiring
        // =========================================================================
        final Runnable refreshAll =
                new Runnable() {
                    @Override
                    public void run() {
                        DanmuConfig cfg = state[0];
                        int originCount = cfg.createProvider().getConfiguredOrigins().size();

                        summaryLine.setText(formatConfigSummary(cfg));

                        // Tab state
                        tabDisplay.setSelected(activeTab[0] == 0);
                        tabAdvanced.setSelected(activeTab[0] == 1);
                        int advCount = originCount + cfg.blockRules.size();
                        tabAdvanced.setText(advCount > 0 ? "源与屏蔽 · " + advCount : "源与屏蔽");
                        stylePill(tabDisplay, tabDisplay.hasFocus(), d, isTv, reducedMotion);
                        stylePill(tabAdvanced, tabAdvanced.hasFocus(), d, isTv, reducedMotion);
                        displayPane.setVisibility(activeTab[0] == 0 ? View.VISIBLE : View.GONE);
                        advancedPane.setVisibility(activeTab[0] == 1 ? View.VISIBLE : View.GONE);

                        // Master switch
                        masterToggle.setSelected(cfg.enabled);
                        masterToggle.setText(cfg.enabled ? "● 已开启" : "已关闭");
                        stylePill(masterToggle, masterToggle.hasFocus(), d, isTv, reducedMotion);
                        controlsCard.setAlpha(cfg.enabled ? 1.0f : 0.72f);

                        // Badges
                        rowsBadge.setText(cfg.maxRows + "行");
                        fontBadge.setText(Math.round(cfg.fontSizeSp) + "sp");
                        speedBadge.setText(formatSpeedShort(cfg.speedMultiplier));
                        opacityBadge.setText(Math.round(cfg.opacity * 100f) + "%");
                        areaBadge.setText(formatAreaShort(cfg.displayArea));
                        offsetBadge.setText(formatOffsetShort(cfg.timeOffsetMs));

                        // Row presets
                        for (int i = 0; i < rowPresetValues.length; i++) {
                            rowPills[i].setSelected(cfg.maxRows == rowPresetValues[i]);
                            stylePill(rowPills[i], rowPills[i].hasFocus(), d, isTv, reducedMotion);
                        }
                        // Font presets
                        for (int i = 0; i < fontPresetValues.length; i++) {
                            fontPills[i].setSelected(
                                    Math.abs(cfg.fontSizeSp - fontPresetValues[i]) < 0.5f);
                            stylePill(
                                    fontPills[i], fontPills[i].hasFocus(), d, isTv, reducedMotion);
                        }
                        // Speed presets
                        for (int i = 0; i < SPEED_OPTIONS.length; i++) {
                            speedPills[i].setSelected(
                                    Math.abs(cfg.speedMultiplier - SPEED_OPTIONS[i]) < 0.01f);
                            stylePill(
                                    speedPills[i],
                                    speedPills[i].hasFocus(),
                                    d,
                                    isTv,
                                    reducedMotion);
                        }
                        // Opacity presets
                        for (int i = 0; i < opacityPresetValues.length; i++) {
                            opacityPills[i].setSelected(
                                    Math.abs(cfg.opacity - opacityPresetValues[i]) < 0.01f);
                            stylePill(
                                    opacityPills[i],
                                    opacityPills[i].hasFocus(),
                                    d,
                                    isTv,
                                    reducedMotion);
                        }
                        // Area presets
                        for (int i = 0; i < AREA_OPTIONS.length; i++) {
                            areaPills[i].setSelected(
                                    Math.abs(cfg.displayArea - AREA_OPTIONS[i]) < 0.01f);
                            stylePill(
                                    areaPills[i], areaPills[i].hasFocus(), d, isTv, reducedMotion);
                        }

                        // Position chips
                        scrollChip.setSelected(cfg.showScroll);
                        scrollChip.setText(cfg.showScroll ? "✓ 滚动" : "滚动");
                        stylePill(scrollChip, scrollChip.hasFocus(), d, isTv, reducedMotion);

                        topChip.setSelected(cfg.showTop);
                        topChip.setText(cfg.showTop ? "✓ 顶部" : "顶部");
                        stylePill(topChip, topChip.hasFocus(), d, isTv, reducedMotion);

                        bottomChip.setSelected(cfg.showBottom);
                        bottomChip.setText(cfg.showBottom ? "✓ 底部" : "底部");
                        stylePill(bottomChip, bottomChip.hasFocus(), d, isTv, reducedMotion);

                        // Time offset zero indicator
                        offsetReset.setSelected(cfg.timeOffsetMs == 0L);
                        stylePill(offsetReset, offsetReset.hasFocus(), d, isTv, reducedMotion);

                        // Advanced tab badges & rules summary
                        serverBadge.setText(originCount > 0 ? "已配置 " + originCount + " 个" : "未配置");
                        rulesBadge.setText(cfg.blockRules.size() + " / " + BlockFilter.MAX_RULES);
                        rulesSummary.setText(formatRulesSummary(cfg.blockRules));
                    }
                };
        refreshAll.run();

        // Tab switchers
        tabDisplay.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        if (activeTab[0] == 0) return;
                        activeTab[0] = 0;
                        scroll.scrollTo(0, 0);
                        refreshAll.run();
                    }
                });
        tabAdvanced.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        if (activeTab[0] == 1) return;
                        activeTab[0] = 1;
                        scroll.scrollTo(0, 0);
                        refreshAll.run();
                    }
                });

        // Reset display defaults (keeps custom server URLs & blocklist intact)
        resetBtn.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        state[0] = resetDisplayDefaults(state[0]);
                        persistAndNotify(context, state[0], listener);
                        refreshAll.run();
                    }
                });

        // Master enable switch
        masterToggle.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.enabled = !state[0].enabled;
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                        refreshAll.run();
                    }
                });

        // Row presets
        for (int i = 0; i < rowPresetValues.length; i++) {
            final int rows = rowPresetValues[i];
            rowPills[i].setOnClickListener(
                    new View.OnClickListener() {
                        @Override
                        public void onClick(View v) {
                            DanmuConfig.Builder b = state[0].toBuilder();
                            b.maxRows = rows;
                            state[0] = b.build();
                            persistAndNotify(context, state[0], listener);
                            refreshAll.run();
                        }
                    });
        }

        // Font presets
        for (int i = 0; i < fontPresetValues.length; i++) {
            final float fontSp = fontPresetValues[i];
            fontPills[i].setOnClickListener(
                    new View.OnClickListener() {
                        @Override
                        public void onClick(View v) {
                            DanmuConfig.Builder b = state[0].toBuilder();
                            b.fontSizeSp = fontSp;
                            state[0] = b.build();
                            persistAndNotify(context, state[0], listener);
                            refreshAll.run();
                        }
                    });
        }

        // Speed presets
        for (int i = 0; i < SPEED_OPTIONS.length; i++) {
            final float speed = SPEED_OPTIONS[i];
            speedPills[i].setOnClickListener(
                    new View.OnClickListener() {
                        @Override
                        public void onClick(View v) {
                            DanmuConfig.Builder b = state[0].toBuilder();
                            b.speedMultiplier = speed;
                            state[0] = b.build();
                            persistAndNotify(context, state[0], listener);
                            refreshAll.run();
                        }
                    });
        }

        // Opacity presets
        for (int i = 0; i < opacityPresetValues.length; i++) {
            final float opacity = opacityPresetValues[i];
            opacityPills[i].setOnClickListener(
                    new View.OnClickListener() {
                        @Override
                        public void onClick(View v) {
                            DanmuConfig.Builder b = state[0].toBuilder();
                            b.opacity = opacity;
                            state[0] = b.build();
                            persistAndNotify(context, state[0], listener);
                            refreshAll.run();
                        }
                    });
        }

        // Area presets
        for (int i = 0; i < AREA_OPTIONS.length; i++) {
            final float area = AREA_OPTIONS[i];
            areaPills[i].setOnClickListener(
                    new View.OnClickListener() {
                        @Override
                        public void onClick(View v) {
                            DanmuConfig.Builder b = state[0].toBuilder();
                            b.displayArea = area;
                            state[0] = b.build();
                            persistAndNotify(context, state[0], listener);
                            refreshAll.run();
                        }
                    });
        }

        // Position toggles
        scrollChip.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.showScroll = !state[0].showScroll;
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                        refreshAll.run();
                    }
                });
        topChip.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.showTop = !state[0].showTop;
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                        refreshAll.run();
                    }
                });
        bottomChip.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.showBottom = !state[0].showBottom;
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                        refreshAll.run();
                    }
                });

        // Time offset stepper
        offsetMinus.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.timeOffsetMs = clampTimeOffsetMs(state[0].timeOffsetMs - 500L);
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                        refreshAll.run();
                    }
                });
        offsetReset.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.timeOffsetMs = 0L;
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                        refreshAll.run();
                    }
                });
        offsetPlus.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.timeOffsetMs = clampTimeOffsetMs(state[0].timeOffsetMs + 500L);
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                        refreshAll.run();
                    }
                });

        // Save server config
        saveServerBtn.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.serverUrls = serverUrlsInput.getText().toString().trim();
                        b.appId = appIdInput.getText().toString().trim();
                        b.appSecret = appSecretInput.getText().toString().trim();
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                        int origins = state[0].createProvider().getConfiguredOrigins().size();
                        serverFeedback.setText(
                                origins > 0 ? "✓ 已保存，生效 " + origins + " 个服务源" : "已保存（当前未配置服务源）");
                        serverFeedback.setTextColor(
                                origins > 0 ? COLOR_GREEN : COLOR_TEXT_SECONDARY);
                        serverFeedback.setVisibility(View.VISIBLE);
                        refreshAll.run();
                    }
                });

        // Blocklist actions
        addRuleBtn.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        String candidate = ruleInput.getText().toString().trim();
                        BlockFilter.ValidationResult vr = BlockFilter.validateRule(candidate);
                        if (!vr.valid) {
                            ruleError.setText(vr.error);
                            ruleError.setVisibility(View.VISIBLE);
                            return;
                        }
                        if (state[0].blockRules.size() >= BlockFilter.MAX_RULES) {
                            ruleError.setText("屏蔽规则已达 100 条上限");
                            ruleError.setVisibility(View.VISIBLE);
                            return;
                        }
                        ruleError.setVisibility(View.GONE);
                        DanmuConfig.Builder b = state[0].toBuilder();
                        if (!b.blockRules.contains(candidate)) {
                            b.blockRules.add(candidate);
                        }
                        state[0] = b.build();
                        ruleInput.setText("");
                        persistAndNotify(context, state[0], listener);
                        refreshAll.run();
                    }
                });
        clearRulesBtn.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        ruleError.setVisibility(View.GONE);
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.blockRules.clear();
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                        refreshAll.run();
                    }
                });

        return shell;
    }

    private static void persistAndNotify(
            Context context, DanmuConfig config, OnConfigChangedListener listener) {
        saveConfig(context, config);
        if (listener != null) {
            listener.onDanmuConfigChanged(config);
        }
    }

    private static String formatRulesSummary(List<String> rules) {
        if (rules.isEmpty()) return "暂无屏蔽规则，添加后即时过滤匹配弹幕";
        StringBuilder sb = new StringBuilder("已生效：");
        int shown = Math.min(6, rules.size());
        for (int i = 0; i < shown; i++) {
            if (i > 0) sb.append("、");
            sb.append(rules.get(i));
        }
        if (rules.size() > shown) {
            sb.append(" 等 ").append(rules.size()).append(" 条");
        }
        return sb.toString();
    }

    private enum PillStyle {
        SEGMENT,
        CHIP,
        SWITCH,
        PRIMARY,
        SUBTLE
    }

    private static int dp(float density, float value) {
        return Math.round(value * density);
    }

    private static GradientDrawable roundedShape(
            int color, float radiusPx, int strokeColor, int strokePx) {
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(color);
        bg.setCornerRadius(radiusPx);
        if (strokePx > 0) {
            bg.setStroke(strokePx, strokeColor);
        }
        return bg;
    }

    private static LinearLayout makeGlassCard(Context context, float d, float radiusDp) {
        LinearLayout card = new LinearLayout(context);
        card.setClipChildren(false);
        card.setClipToPadding(false);
        UiCompat.setBackground(
                card,
                roundedShape(
                        COLOR_CARD_BG, radiusDp * d, COLOR_CARD_STROKE, Math.max(1, dp(d, 1))));
        return card;
    }

    private static LinearLayout makeSegmentTrack(Context context, float d) {
        LinearLayout track = new LinearLayout(context);
        track.setOrientation(LinearLayout.HORIZONTAL);
        track.setGravity(Gravity.CENTER_VERTICAL);
        track.setClipChildren(false);
        track.setClipToPadding(false);
        int p = dp(d, 2);
        track.setPadding(p, p, p, p);
        UiCompat.setBackground(
                track,
                roundedShape(COLOR_TRACK_BG, 999f * d, COLOR_TRACK_STROKE, Math.max(1, dp(d, 1))));
        return track;
    }

    private static void addSegmentPill(LinearLayout track, TextView pill, float d, boolean isTv) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, dp(d, isTv ? 28 : 34), 1f);
        track.addView(pill, lp);
    }

    private static void addChip(
            LinearLayout row, TextView chip, float d, boolean isTv, boolean addEndGap) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, dp(d, isTv ? 30 : 36), 1f);
        if (addEndGap) lp.rightMargin = dp(d, 6);
        row.addView(chip, lp);
    }

    private static TextView makeValueBadge(Context context, float d) {
        TextView badge = new TextView(context);
        badge.setTextColor(COLOR_ACCENT_TEXT);
        badge.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f);
        badge.setTypeface(null, Typeface.BOLD);
        badge.setSingleLine(true);
        badge.setGravity(Gravity.CENTER);
        badge.setPadding(dp(d, 8), dp(d, 2), dp(d, 8), dp(d, 2));
        UiCompat.setBackground(badge, roundedShape(COLOR_ACCENT_SOFT, 999f * d, 0, 0));
        return badge;
    }

    private static void addControlRow(
            LinearLayout parent,
            Context context,
            String label,
            TextView valueBadge,
            View control,
            float d,
            boolean isTv,
            boolean addTopDivider) {
        if (addTopDivider) {
            View divider = new View(context);
            divider.setBackgroundColor(COLOR_DIVIDER);
            LinearLayout.LayoutParams dlp =
                    new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1);
            dlp.leftMargin = dp(d, 14);
            dlp.rightMargin = dp(d, 14);
            parent.addView(divider, dlp);
        }

        LinearLayout row = new LinearLayout(context);
        row.setClipChildren(false);
        row.setClipToPadding(false);

        TextView title = new TextView(context);
        title.setText(label);
        title.setTextColor(COLOR_TEXT_PRIMARY);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, isTv ? 14f : 13.5f);
        title.setTypeface(null, Typeface.BOLD);
        title.setSingleLine(true);

        if (isTv) {
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(dp(d, 14), dp(d, 5), dp(d, 14), dp(d, 5));

            LinearLayout leftMeta = new LinearLayout(context);
            leftMeta.setOrientation(LinearLayout.HORIZONTAL);
            leftMeta.setGravity(Gravity.CENTER_VERTICAL);
            leftMeta.addView(title);
            if (valueBadge != null) {
                LinearLayout.LayoutParams blp =
                        new LinearLayout.LayoutParams(
                                ViewGroup.LayoutParams.WRAP_CONTENT,
                                ViewGroup.LayoutParams.WRAP_CONTENT);
                blp.leftMargin = dp(d, 8);
                leftMeta.addView(valueBadge, blp);
            }
            LinearLayout.LayoutParams leftLp =
                    new LinearLayout.LayoutParams(dp(d, 156), ViewGroup.LayoutParams.WRAP_CONTENT);
            leftLp.rightMargin = dp(d, 12);
            row.addView(leftMeta, leftLp);
            row.addView(
                    control,
                    new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        } else {
            row.setOrientation(LinearLayout.VERTICAL);
            row.setPadding(dp(d, 12), dp(d, 9), dp(d, 12), dp(d, 9));

            LinearLayout header = new LinearLayout(context);
            header.setOrientation(LinearLayout.HORIZONTAL);
            header.setGravity(Gravity.CENTER_VERTICAL);
            header.addView(
                    title,
                    new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
            if (valueBadge != null) {
                header.addView(valueBadge);
            }
            row.addView(header);
            LinearLayout.LayoutParams ctlLp =
                    new LinearLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.WRAP_CONTENT);
            ctlLp.topMargin = dp(d, 7);
            row.addView(control, ctlLp);
        }

        parent.addView(row);
    }

    private static LinearLayout makeCardHeader(
            Context context, String title, TextView badge, float d) {
        LinearLayout header = new LinearLayout(context);
        header.setOrientation(LinearLayout.HORIZONTAL);
        header.setGravity(Gravity.CENTER_VERTICAL);
        TextView tv = new TextView(context);
        tv.setText(title);
        tv.setTextColor(COLOR_TEXT_PRIMARY);
        tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14.5f);
        tv.setTypeface(null, Typeface.BOLD);
        header.addView(
                tv, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        if (badge != null) {
            header.addView(badge);
        }
        return header;
    }

    private static TextView makeCardCaption(Context context, String text, float d) {
        TextView tv = new TextView(context);
        tv.setText(text);
        tv.setTextColor(COLOR_TEXT_SECONDARY);
        tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f);
        LinearLayout.LayoutParams lp =
                new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(d, 4);
        tv.setLayoutParams(lp);
        return tv;
    }

    private static TextView makePill(
            Context context,
            String text,
            final float d,
            final boolean isTv,
            final boolean reducedMotion,
            PillStyle style) {
        final TextView pill = new TextView(context);
        pill.setText(text);
        pill.setTag(style);
        pill.setGravity(Gravity.CENTER);
        pill.setSingleLine(true);
        pill.setEllipsize(TextUtils.TruncateAt.END);
        pill.setFocusable(true);
        pill.setClickable(true);
        pill.setTextSize(TypedValue.COMPLEX_UNIT_SP, isTv ? 13f : 12.5f);
        pill.setPadding(dp(d, 8), 0, dp(d, 8), 0);
        UiCompat.setDefaultFocusHighlightEnabled(pill, false);
        stylePill(pill, false, d, isTv, reducedMotion);
        pill.setOnFocusChangeListener(
                new View.OnFocusChangeListener() {
                    @Override
                    public void onFocusChange(View v, boolean hasFocus) {
                        stylePill(pill, hasFocus, d, isTv, reducedMotion);
                    }
                });
        return pill;
    }

    private static void stylePill(
            TextView pill, boolean focused, float d, boolean isTv, boolean reducedMotion) {
        PillStyle style =
                pill.getTag() instanceof PillStyle ? (PillStyle) pill.getTag() : PillStyle.SEGMENT;
        boolean selected = pill.isSelected();
        GradientDrawable bg;
        int textColor;
        boolean bold = focused || selected || style == PillStyle.PRIMARY;

        if (focused) {
            bg = roundedShape(COLOR_FOCUS_FILL, 999f * d, 0xFFFFFFFF, Math.max(2, dp(d, 2)));
            textColor = COLOR_FOCUS_TEXT;
        } else if (style == PillStyle.SWITCH) {
            if (selected) {
                bg =
                        roundedShape(
                                COLOR_GREEN_SOFT,
                                999f * d,
                                COLOR_GREEN_STROKE,
                                Math.max(1, dp(d, 1)));
                textColor = 0xFFE9FFF0;
            } else {
                bg =
                        roundedShape(
                                COLOR_PILL_IDLE,
                                999f * d,
                                COLOR_CARD_STROKE,
                                Math.max(1, dp(d, 1)));
                textColor = COLOR_TEXT_SECONDARY;
            }
        } else if (style == PillStyle.PRIMARY) {
            bg = roundedShape(0xEB0A84FF, 999f * d, 0x55FFFFFF, Math.max(1, dp(d, 1)));
            textColor = 0xFFFFFFFF;
        } else if (style == PillStyle.SUBTLE) {
            bg = roundedShape(COLOR_PILL_IDLE, 999f * d, COLOR_CARD_STROKE, Math.max(1, dp(d, 1)));
            textColor = COLOR_PILL_IDLE_TEXT;
        } else if (style == PillStyle.CHIP) {
            if (selected) {
                bg = roundedShape(0xDF0A84FF, 999f * d, 0x66FFFFFF, Math.max(1, dp(d, 1)));
                textColor = 0xFFFFFFFF;
            } else {
                bg = roundedShape(0x28000000, 999f * d, COLOR_TRACK_STROKE, Math.max(1, dp(d, 1)));
                textColor = COLOR_TEXT_SECONDARY;
            }
        } else {
            // SEGMENT
            if (selected) {
                bg = roundedShape(COLOR_ACCENT, 999f * d, 0x55FFFFFF, Math.max(1, dp(d, 1)));
                textColor = 0xFFFFFFFF;
            } else {
                bg = roundedShape(0x00000000, 999f * d, 0, 0);
                textColor = COLOR_PILL_IDLE_TEXT;
            }
        }

        UiCompat.setBackground(pill, bg);
        pill.setTextColor(textColor);
        pill.setTypeface(null, bold ? Typeface.BOLD : Typeface.NORMAL);
        float scale = (focused && isTv && !reducedMotion) ? 1.04f : 1.0f;
        pill.setScaleX(scale);
        pill.setScaleY(scale);
        UiCompat.setElevation(pill, focused ? 4f * d : 0f);
    }

    private static EditText makeInput(
            Context context, String initial, String hint, boolean multiline, final float d) {
        final EditText et = new EditText(context);
        et.setText(initial);
        et.setHint(hint);
        et.setTextColor(COLOR_TEXT_PRIMARY);
        et.setHintTextColor(COLOR_TEXT_SECONDARY);
        et.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13.5f);
        et.setFocusable(true);
        et.setPadding(dp(d, 12), dp(d, 8), dp(d, 12), dp(d, 8));
        UiCompat.setDefaultFocusHighlightEnabled(et, false);
        UiCompat.setBackground(
                et, roundedShape(0x3B000000, 12f * d, 0x2AFFFFFF, Math.max(1, dp(d, 1))));
        et.setOnFocusChangeListener(
                new View.OnFocusChangeListener() {
                    @Override
                    public void onFocusChange(View v, boolean hasFocus) {
                        UiCompat.setBackground(
                                et,
                                roundedShape(
                                        hasFocus ? 0x52000000 : 0x3B000000,
                                        12f * d,
                                        hasFocus ? 0xE6FFFFFF : 0x2AFFFFFF,
                                        Math.max(1, dp(d, hasFocus ? 2 : 1))));
                    }
                });
        if (multiline) {
            et.setInputType(
                    InputType.TYPE_CLASS_TEXT
                            | InputType.TYPE_TEXT_FLAG_MULTI_LINE
                            | InputType.TYPE_TEXT_VARIATION_URI);
            et.setMinLines(2);
            et.setMaxLines(3);
            et.setGravity(Gravity.TOP | Gravity.LEFT);
        } else {
            et.setSingleLine(true);
        }
        return et;
    }
}
