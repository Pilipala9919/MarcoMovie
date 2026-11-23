// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.content.Context;
import android.content.SharedPreferences;
import android.content.res.AssetManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Outline;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.util.DisplayMetrics;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewOutlineProvider;
import android.view.animation.PathInterpolator;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Standalone 5-act story onboarding view for Android Mobile, Tablet, and Android TV.
 *
 * <p>Uses a dedicated device-local {@link SharedPreferences} file ({@link #PREFS_FILE}) and never
 * touches {@code Prefs.java} or cross-device backup keys. TV mode enforces zero blur/shaders, a
 * full D-pad focus chain with visible focus stroke/fill even under {@code reduceMotion}, and
 * Back-key step-back/skip support.
 */
public final class OnboardingScreen extends FrameLayout {

    public static final String PREFS_FILE = "marco_onboarding_local";
    public static final String KEY_ONBOARDING_DONE_VERSION = "onboarding_done_version";
    public static final String KEY_PLAY_HINT_SHOWN_COUNT = "play_hint_shown_count";
    public static final String KEY_PLAY_HINT_DISMISSED = "play_hint_dismissed";
    public static final int CURRENT_VERSION = 1;
    public static final int ACT_COUNT = 5;
    public static final int[] SUPPORTED_UI_SCALES = {100, 110, 120};

    private static final int COLOR_BG_TOP = 0xFF09090C;
    private static final int COLOR_BG_MID = 0xFF101829;
    private static final int COLOR_BG_BOT = 0xFF09090C;
    private static final int COLOR_CARD_GLASS = 0xCC161822;
    private static final int COLOR_CARD_SOLID = 0xF51E1E22;
    private static final int COLOR_BORDER = 0x38FFFFFF;
    private static final int COLOR_BORDER_HIGH = 0x73FFFFFF;
    private static final int COLOR_ACCENT = 0xFF0A84FF;
    private static final int COLOR_TEAL = 0xFF5AC8FA;
    private static final int COLOR_PURPLE = 0xFFBF5AF2;
    private static final int COLOR_GOLD = 0xFFFFB340;
    private static final int COLOR_WHITE = 0xFFF5F5F7;
    private static final int COLOR_MUTED = 0xFFB0B3C2;
    private static final int COLOR_FOCUS_TEXT = 0xFF101013;

    private static final String FOCUS_TAG_REDUCE_MOTION = "act5_reduce_motion";
    private static final String FOCUS_TAG_REDUCE_TRANS = "act5_reduce_trans";
    private static final String FOCUS_TAG_SCALE_PREFIX = "act5_scale_";
    private static final String FOCUS_TAG_HUD_STEP = "act4_hud_step";

    /** Device-local key-value abstraction so state logic is unit-testable on the JVM. */
    public interface Store {
        int getInt(String key, int defaultValue);

        void putInt(String key, int value);

        boolean getBoolean(String key, boolean defaultValue);

        void putBoolean(String key, boolean value);
    }

    /** Android {@link SharedPreferences} adapter backed by {@link #PREFS_FILE}. */
    public static final class SharedPrefsStore implements Store {
        private final SharedPreferences prefs;

        public SharedPrefsStore(Context context) {
            this.prefs = context.getApplicationContext().getSharedPreferences(PREFS_FILE, 0);
        }

        @Override
        public int getInt(String key, int defaultValue) {
            return prefs.getInt(key, defaultValue);
        }

        @Override
        public void putInt(String key, int value) {
            prefs.edit().putInt(key, value).apply();
        }

        @Override
        public boolean getBoolean(String key, boolean defaultValue) {
            return prefs.getBoolean(key, defaultValue);
        }

        @Override
        public void putBoolean(String key, boolean value) {
            prefs.edit().putBoolean(key, value).apply();
        }
    }

    /** In-memory {@link Store} for deterministic offline JVM verification. */
    public static final class MemoryStore implements Store {
        private final Map<String, Integer> ints = new HashMap<String, Integer>();
        private final Map<String, Boolean> bools = new HashMap<String, Boolean>();

        @Override
        public int getInt(String key, int defaultValue) {
            Integer v = ints.get(key);
            return v != null ? v.intValue() : defaultValue;
        }

        @Override
        public void putInt(String key, int value) {
            ints.put(key, Integer.valueOf(value));
        }

        @Override
        public boolean getBoolean(String key, boolean defaultValue) {
            Boolean v = bools.get(key);
            return v != null ? v.booleanValue() : defaultValue;
        }

        @Override
        public void putBoolean(String key, boolean value) {
            bools.put(key, Boolean.valueOf(value));
        }
    }

    /** Strictly fictional demo poster metadata parsed from {@code assets/demo/manifest.json}. */
    public static final class DemoItem {
        public final String id;
        public final String file;
        public final String titleZh;
        public final String titleEn;
        public final String badgeZh;
        public final String badgeEn;
        public final List<String> specs;
        public final float progress;
        public final int accentColor;

        public DemoItem(
                String id,
                String file,
                String titleZh,
                String titleEn,
                String badgeZh,
                String badgeEn,
                List<String> specs,
                float progress,
                int accentColor) {
            this.id = id;
            this.file = file;
            this.titleZh = titleZh;
            this.titleEn = titleEn;
            this.badgeZh = badgeZh;
            this.badgeEn = badgeEn;
            this.specs = Collections.unmodifiableList(new ArrayList<String>(specs));
            this.progress = Math.max(0f, Math.min(1f, progress));
            this.accentColor = accentColor;
        }

        public String title(boolean zh) {
            return zh ? titleZh : titleEn;
        }

        public String badgeLabel(boolean zh) {
            return zh ? badgeZh : badgeEn;
        }
    }

    /** Pure-Java 5-act navigation, personalization, and persistence state machine. */
    public static final class Controller {
        private final Store store;
        private int currentAct;
        private int hudDemoStep;
        private boolean reduceMotion;
        private boolean reduceTransparency;
        private int uiScalePercent = 100;
        private boolean finished;
        private boolean skipped;

        public Controller(Store store) {
            this.store = store;
        }

        public static boolean shouldShowOnLaunch(Store store) {
            return store != null && store.getInt(KEY_ONBOARDING_DONE_VERSION, 0) < CURRENT_VERSION;
        }

        public static void markCompleted(Store store) {
            if (store != null) {
                store.putInt(KEY_ONBOARDING_DONE_VERSION, CURRENT_VERSION);
            }
        }

        /** Resets onboarding and first-play hint state when user replays onboarding from Settings. */
        public static void resetForReplay(Store store) {
            if (store != null) {
                store.putInt(KEY_ONBOARDING_DONE_VERSION, 0);
                store.putInt(KEY_PLAY_HINT_SHOWN_COUNT, 0);
                store.putBoolean(KEY_PLAY_HINT_DISMISSED, false);
            }
        }

        public int getCurrentAct() {
            return currentAct;
        }

        public boolean isFirstAct() {
            return currentAct == 0;
        }

        public boolean isLastAct() {
            return currentAct == ACT_COUNT - 1;
        }

        public boolean nextAct() {
            if (currentAct < ACT_COUNT - 1) {
                currentAct++;
                return true;
            }
            return false;
        }

        public boolean previousAct() {
            if (currentAct > 0) {
                currentAct--;
                return true;
            }
            return false;
        }

        public void goToAct(int index) {
            if (index < 0) {
                currentAct = 0;
            } else if (index >= ACT_COUNT) {
                currentAct = ACT_COUNT - 1;
            } else {
                currentAct = index;
            }
        }

        public int getHudDemoStep() {
            return hudDemoStep;
        }

        public int cycleHudDemoStep() {
            hudDemoStep = (hudDemoStep + 1) % 3;
            return hudDemoStep;
        }

        public void complete(boolean wasSkipped) {
            finished = true;
            skipped = wasSkipped;
            markCompleted(store);
        }

        /**
         * Handles hardware Back key: steps back to previous act if past Act 1, otherwise skips
         * onboarding cleanly (satisfying TV & mobile Back-key contract).
         */
        public boolean handleBack() {
            if (currentAct > 0) {
                currentAct--;
                return false;
            }
            complete(true);
            return true;
        }

        public boolean isFinished() {
            return finished;
        }

        public boolean isSkipped() {
            return skipped;
        }

        public boolean isReduceMotion() {
            return reduceMotion;
        }

        public void setReduceMotion(boolean value) {
            this.reduceMotion = value;
        }

        public boolean isReduceTransparency() {
            return reduceTransparency;
        }

        public void setReduceTransparency(boolean value) {
            this.reduceTransparency = value;
        }

        public int getUiScalePercent() {
            return uiScalePercent;
        }

        public void setUiScalePercent(int percent) {
            if (percent == 100 || percent == 110 || percent == 120) {
                this.uiScalePercent = percent;
            }
        }
    }

    /** Host integration callbacks wired in Wave 2. */
    public interface Callbacks {
        void onImportConfig(String initialEmptyUrl);

        void onOpenSync();

        void onPersonalizationChanged(
                boolean reduceMotion, boolean reduceTransparency, int uiScalePercent);

        void onFinished(boolean skipped);
    }

    private final Controller controller;
    private final boolean tvMode;
    private final boolean zh;
    private final Callbacks callbacks;
    private final List<DemoItem> demoItems;
    private final Map<String, Bitmap> posterBitmaps = new HashMap<String, Bitmap>();
    private final FrameLayout backgroundSlot;
    private final LinearLayout rootColumn;
    private final FrameLayout stageContainer;
    private final LinearLayout dotsRow;
    private final TextView brandView;
    private final TextView skipButton;
    private final TextView prevButton;
    private final TextView nextButton;
    private TextView primaryCtaButton;
    private Runnable pendingFocusTask;
    private boolean backDownTracked;

    public OnboardingScreen(
            Context context,
            boolean tvMode,
            boolean reduceMotion,
            boolean reduceTransparency,
            int initialUiScalePercent,
            Callbacks callbacks) {
        this(
                context,
                new SharedPrefsStore(context),
                tvMode,
                isChineseLocale(),
                reduceMotion,
                reduceTransparency,
                initialUiScalePercent,
                callbacks);
    }

    public OnboardingScreen(
            Context context,
            Store store,
            boolean tvMode,
            boolean chinese,
            boolean reduceMotion,
            boolean reduceTransparency,
            int initialUiScalePercent,
            Callbacks callbacks) {
        super(context);
        this.controller = new Controller(store);
        this.controller.setReduceMotion(reduceMotion);
        this.controller.setReduceTransparency(reduceTransparency);
        this.controller.setUiScalePercent(initialUiScalePercent);
        this.tvMode = tvMode;
        this.zh = chinese;
        this.callbacks = callbacks;
        this.demoItems = loadDemoItems(context);

        setClickable(true);
        UiCompat.setDefaultFocusHighlightEnabled(this, false);
        setFocusable(true);
        setFocusableInTouchMode(true);
        setClipChildren(false);
        setClipToPadding(false);

        // Background layer: static dark gradient (zero blur/shaders on TV).
        this.backgroundSlot = new FrameLayout(context);
        GradientDrawable bg =
                new GradientDrawable(
                        GradientDrawable.Orientation.TL_BR,
                        new int[] {COLOR_BG_TOP, COLOR_BG_MID, COLOR_BG_BOT});
        UiCompat.setBackground(backgroundSlot, bg);
        addView(
                backgroundSlot,
                new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT));

        this.rootColumn = new LinearLayout(context);
        rootColumn.setOrientation(LinearLayout.VERTICAL);
        rootColumn.setClipChildren(false);
        rootColumn.setClipToPadding(false);
        int padH = dp(tvMode ? 44 : 20);
        int padV = dp(tvMode ? 28 : 18);
        rootColumn.setPadding(padH, padV, padH, padV);
        addView(rootColumn, new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT));

        // Top bar: brand label + Skip button (available on every act).
        LinearLayout topBar = new LinearLayout(context);
        topBar.setOrientation(LinearLayout.HORIZONTAL);
        topBar.setGravity(Gravity.CENTER_VERTICAL);
        topBar.setClipChildren(false);
        topBar.setClipToPadding(false);

        this.brandView =
                makeText(
                        zh ? "Marco Movie · 新手引导" : "Marco Movie · Welcome", 15, COLOR_WHITE, true);
        LinearLayout.LayoutParams brandLp =
                new LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f);
        topBar.addView(brandView, brandLp);

        this.skipButton = makeActionPill(zh ? "跳过" : "Skip", false);
        skipButton.setId(UiCompat.generateViewId());
        skipButton.setOnClickListener(
                new OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        finishOnboarding(true);
                    }
                });
        topBar.addView(skipButton);
        rootColumn.addView(
                topBar,
                new LinearLayout.LayoutParams(
                        LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT));

        // Center stage container (rebuilt on act change).
        this.stageContainer = new FrameLayout(context);
        stageContainer.setClipChildren(false);
        stageContainer.setClipToPadding(false);
        LinearLayout.LayoutParams stageLp =
                new LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f);
        stageLp.topMargin = dp(14);
        stageLp.bottomMargin = dp(14);
        rootColumn.addView(stageContainer, stageLp);

        // Bottom navigation bar: Prev | Progress Dots | Next / Start.
        LinearLayout bottomBar = new LinearLayout(context);
        bottomBar.setOrientation(LinearLayout.HORIZONTAL);
        bottomBar.setGravity(Gravity.CENTER_VERTICAL);
        bottomBar.setClipChildren(false);
        bottomBar.setClipToPadding(false);

        this.prevButton = makeActionPill(zh ? "上一幕" : "Back", false);
        prevButton.setId(UiCompat.generateViewId());
        prevButton.setOnClickListener(
                new OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        if (controller.previousAct()) {
                            renderAct(null);
                        }
                    }
                });
        bottomBar.addView(prevButton);

        this.dotsRow = new LinearLayout(context);
        dotsRow.setOrientation(LinearLayout.HORIZONTAL);
        dotsRow.setGravity(Gravity.CENTER);
        bottomBar.addView(dotsRow, new LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f));

        this.nextButton = makeActionPill(zh ? "下一幕" : "Next", true);
        nextButton.setId(UiCompat.generateViewId());
        nextButton.setOnClickListener(
                new OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        if (controller.nextAct()) {
                            renderAct(null);
                        } else {
                            finishOnboarding(false);
                        }
                    }
                });
        bottomBar.addView(nextButton);
        rootColumn.addView(
                bottomBar,
                new LinearLayout.LayoutParams(
                        LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT));

        renderAct(null);
    }

    /** Optional Wave 2 hook to mount AuroraSurfaceView on non-TV devices. */
    public void setBackgroundLayer(View layer) {
        if (tvMode || layer == null) {
            return;
        }
        backgroundSlot.removeAllViews();
        backgroundSlot.addView(
                layer, new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT));
    }

    public Controller getController() {
        return controller;
    }

    public static boolean shouldShow(Context context) {
        return Controller.shouldShowOnLaunch(new SharedPrefsStore(context));
    }

    public static void resetForReplay(Context context) {
        Controller.resetForReplay(new SharedPrefsStore(context));
    }

    /**
     * Public Back-press handler for Wave 2 {@code Activity.onBackPressed()} / Android 10–15
     * predictive gesture back and touch-mode navigation.
     *
     * @return always {@code true} indicating the Back event was handled by onboarding.
     */
    public boolean handleBackPressed() {
        boolean exited = controller.handleBack();
        if (exited) {
            notifyFinished(true);
        } else {
            renderAct(null);
        }
        return true;
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        if (event != null && event.getKeyCode() == KeyEvent.KEYCODE_BACK) {
            if (event.getAction() == KeyEvent.ACTION_DOWN) {
                if (event.getRepeatCount() == 0) {
                    event.startTracking();
                    backDownTracked = true;
                }
                return true;
            }
            if (event.getAction() == KeyEvent.ACTION_UP) {
                boolean wasTracked = backDownTracked;
                backDownTracked = false;
                if (wasTracked && !event.isCanceled()) {
                    return handleBackPressed();
                }
                return true;
            }
        }
        return super.dispatchKeyEvent(event);
    }

    @Override
    protected void onDetachedFromWindow() {
        cancelPendingFocus();
        // Detach ImageViews before recycling bitmaps to prevent draw-after-recycle crashes.
        stageContainer.removeAllViews();
        super.onDetachedFromWindow();
        for (Bitmap bmp : posterBitmaps.values()) {
            if (bmp != null && !bmp.isRecycled()) {
                bmp.recycle();
            }
        }
        posterBitmaps.clear();
    }

    private void cancelPendingFocus() {
        if (pendingFocusTask != null) {
            removeCallbacks(pendingFocusTask);
            pendingFocusTask = null;
        }
    }

    private void finishOnboarding(boolean skipped) {
        controller.complete(skipped);
        notifyFinished(skipped);
    }

    private void notifyFinished(boolean skipped) {
        if (callbacks != null) {
            callbacks.onFinished(skipped);
        }
    }

    private void refreshChromeStyles() {
        float scale = controller.getUiScalePercent() / 100f;
        brandView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f * scale);
        float btnSp = (tvMode ? 15f : 14f) * scale;
        skipButton.setTextSize(TypedValue.COMPLEX_UNIT_SP, btnSp);
        prevButton.setTextSize(TypedValue.COMPLEX_UNIT_SP, btnSp);
        nextButton.setTextSize(TypedValue.COMPLEX_UNIT_SP, btnSp);
        stylePill(skipButton, false, skipButton.hasFocus());
        stylePill(prevButton, false, prevButton.hasFocus());
        stylePill(nextButton, true, nextButton.hasFocus());
    }

    /**
     * Rebuilds the active act view. When {@code preserveFocusTag} is non-null (e.g., after toggling
     * an Act 5 personalization control or cycling Act 4 HUD preview), focus stays on the matching
     * tagged control instead of jumping back to the default CTA.
     */
    private void renderAct(final String preserveFocusTag) {
        cancelPendingFocus();
        stageContainer.removeAllViews();
        primaryCtaButton = null;

        int act = controller.getCurrentAct();
        boolean wide = isWideLayout();

        View actView;
        switch (act) {
            case 0:
                actView = buildAct1EmptyShell(wide);
                break;
            case 1:
                actView = buildAct2PosterWall(wide);
                break;
            case 2:
                actView = buildAct3Sync(wide);
                break;
            case 3:
                actView = buildAct4PlaybackHud(wide);
                break;
            default:
                actView = buildAct5Personalize(wide);
                break;
        }

        ScrollView scroll = new ScrollView(getContext());
        scroll.setFillViewport(true);
        scroll.setVerticalScrollBarEnabled(false);
        scroll.setClipChildren(false);
        scroll.setClipToPadding(false);
        scroll.addView(
                actView, new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT));
        stageContainer.addView(
                scroll, new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT));

        prevButton.setVisibility(controller.isFirstAct() ? View.INVISIBLE : View.VISIBLE);
        prevButton.setFocusable(!controller.isFirstAct());
        nextButton.setText(
                controller.isLastAct() ? (zh ? "先进入首页" : "Enter Home") : (zh ? "下一幕" : "Next"));

        refreshChromeStyles();
        renderDots(act);
        wireFocusChain();

        if (tvMode || preserveFocusTag != null) {
            final View preserved =
                    preserveFocusTag != null
                            ? stageContainer.findViewWithTag(preserveFocusTag)
                            : null;
            final View target =
                    preserved != null
                            ? preserved
                            : ((act == ACT_COUNT - 1 && primaryCtaButton != null)
                                    ? primaryCtaButton
                                    : nextButton);
            pendingFocusTask =
                    new Runnable() {
                        @Override
                        public void run() {
                            pendingFocusTask = null;
                            if (UiCompat.isAttached(OnboardingScreen.this) && target != null) {
                                target.requestFocus();
                            }
                        }
                    };
            post(pendingFocusTask);
        }
    }

    private void renderDots(int active) {
        dotsRow.removeAllViews();
        for (int i = 0; i < ACT_COUNT; i++) {
            View dot = new View(getContext());
            int w = dp(i == active ? 22 : 7);
            int h = dp(7);
            GradientDrawable d = new GradientDrawable();
            d.setCornerRadius(dp(4));
            d.setColor(i == active ? COLOR_ACCENT : 0x55FFFFFF);
            UiCompat.setBackground(dot, d);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(w, h);
            lp.leftMargin = dp(4);
            lp.rightMargin = dp(4);
            dotsRow.addView(dot, lp);
        }
    }

    private void wireFocusChain() {
        skipButton.setNextFocusDownId(
                primaryCtaButton != null ? primaryCtaButton.getId() : nextButton.getId());
        if (prevButton.getVisibility() == View.VISIBLE) {
            prevButton.setNextFocusRightId(nextButton.getId());
            nextButton.setNextFocusLeftId(prevButton.getId());
        } else {
            nextButton.setNextFocusLeftId(View.NO_ID);
        }
    }

    private View buildAct1EmptyShell(boolean wide) {
        LinearLayout left =
                makeInfoColumn(
                        zh ? "第 1 幕 · 自有配置与工具边界" : "Act 1 · Your Own Sources",
                        zh ? "纯净播放与内容管理工具" : "A Clean Player & Library Tool",
                        zh
                                ? "Marco Movie 仅作播放与内容管理工具，不内置、不提供、不托管任何影视资源。首次启动配置地址默认为空，由您自行导入合法自有源。"
                                : "Marco Movie is strictly a playback and library tool. It bundles, provides, and hosts zero media content. Initial source address stays empty until you import your own.");

        TextView importBtn = makeActionPill(zh ? "立即导入配置" : "Import Config", true);
        importBtn.setId(UiCompat.generateViewId());
        importBtn.setOnClickListener(
                new OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        if (callbacks != null) {
                            callbacks.onImportConfig("");
                        }
                    }
                });
        primaryCtaButton = importBtn;
        LinearLayout.LayoutParams ctaLp =
                new LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT);
        ctaLp.topMargin = dp(16);
        left.addView(importBtn, ctaLp);

        LinearLayout right = makeGlassCard();
        right.addView(
                makeText(
                        zh ? "空配置地址预览（默认 \"\"）" : "Empty Config Preview (Default \"\")",
                        13,
                        COLOR_TEAL,
                        true));
        TextView inputBox =
                makeText("https://your-own-config.example/config.json", 13, COLOR_MUTED, false);
        GradientDrawable boxBg = new GradientDrawable();
        boxBg.setColor(0x6609090C);
        boxBg.setCornerRadius(dp(10));
        boxBg.setStroke(dp(1), COLOR_BORDER);
        UiCompat.setBackground(inputBox, boxBg);
        inputBox.setPadding(dp(12), dp(10), dp(12), dp(10));
        LinearLayout.LayoutParams boxLp =
                new LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT);
        boxLp.topMargin = dp(10);
        right.addView(inputBox, boxLp);

        String platformHint =
                tvMode
                        ? (zh
                                ? "电视端支持局域网扫码推送与遥控器快速输入"
                                : "TV supports LAN QR push and remote-friendly input")
                        : (zh
                                ? "手机/平板支持剪贴板一键粘贴与本地配置文件导入"
                                : "Mobile & Tablet support one-tap clipboard paste and local file import");
        TextView hintView = makeText(platformHint, 13, COLOR_WHITE, false);
        LinearLayout.LayoutParams hintLp =
                new LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT);
        hintLp.topMargin = dp(12);
        right.addView(hintView, hintLp);

        return assembleSplit(wide, left, right);
    }

    private View buildAct2PosterWall(boolean wide) {
        LinearLayout left =
                makeInfoColumn(
                        zh ? "第 2 幕 · 海报墙、规格徽章与续播" : "Act 2 · Poster Wall & Spec Badges",
                        zh ? "规格一目了然，续播无缝衔接" : "Clear Specs & Seamless Resume",
                        zh
                                ? "以下 14 张抽象几何海报均为程序化生成的虚构示例素材，展示纯文字规格徽章（4K、DV · ATMOS、HDR10+、REMUX）与继续观看进度条。"
                                : "These 14 procedurally generated abstract posters are fictional samples showcasing text-only spec badges (4K, DV · ATMOS, HDR10+, REMUX) and continue-watching progress.");

        LinearLayout right = makeGlassCard();
        right.setClipChildren(false);
        right.setClipToPadding(false);
        right.addView(
                makeText(
                        zh
                                ? "14 张示例海报网格（全部为虚构占位素材）"
                                : "14 Sample Posters Grid (Fictional Placeholders)",
                        13,
                        COLOR_GOLD,
                        true));

        int columns = wide ? 4 : 3;
        LinearLayout grid = new LinearLayout(getContext());
        grid.setOrientation(LinearLayout.VERTICAL);
        grid.setClipChildren(false);
        grid.setClipToPadding(false);
        grid.setPadding(dp(4), dp(8), dp(4), dp(4));

        int count = demoItems.size();
        for (int start = 0; start < count; start += columns) {
            LinearLayout row = new LinearLayout(getContext());
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setClipChildren(false);
            row.setClipToPadding(false);
            for (int col = 0; col < columns; col++) {
                int idx = start + col;
                LinearLayout.LayoutParams cellLp =
                        new LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f);
                if (col > 0) {
                    cellLp.leftMargin = dp(8);
                }
                if (idx < count) {
                    row.addView(buildDemoPosterCard(demoItems.get(idx)), cellLp);
                } else {
                    row.addView(new View(getContext()), cellLp);
                }
            }
            LinearLayout.LayoutParams rowLp =
                    new LinearLayout.LayoutParams(
                            LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT);
            if (start > 0) {
                rowLp.topMargin = dp(10);
            }
            grid.addView(row, rowLp);
        }

        right.addView(
                grid,
                new LinearLayout.LayoutParams(
                        LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT));
        return assembleSplit(wide, left, right);
    }

    private View buildDemoPosterCard(DemoItem item) {
        final LinearLayout card = new LinearLayout(getContext());
        card.setOrientation(LinearLayout.VERTICAL);
        card.setFocusable(tvMode);
        card.setClickable(tvMode);
        card.setClipChildren(false);
        card.setClipToPadding(false);
        card.setPadding(dp(5), dp(5), dp(5), dp(6));
        styleCardContainer(card, false);

        FrameLayout posterWrap = new FrameLayout(getContext());
        int posterH = dp(tvMode ? 128 : 112);
        applyRoundedClip(posterWrap, dp(8));

        ImageView img = new ImageView(getContext());
        img.setScaleType(ImageView.ScaleType.CENTER_CROP);
        Bitmap bmp = loadPosterBitmap(item.file);
        if (bmp != null) {
            img.setImageBitmap(bmp);
        } else {
            GradientDrawable fallback =
                    new GradientDrawable(
                            GradientDrawable.Orientation.TL_BR,
                            new int[] {COLOR_BG_TOP, item.accentColor});
            fallback.setCornerRadius(dp(8));
            UiCompat.setBackground(img, fallback);
        }
        posterWrap.addView(
                img, new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT));

        // Mandatory UI-layer "示例 / DEMO" badge in top-right corner.
        TextView demoBadge = makeText(zh ? "示例" : "DEMO", 9.5f, COLOR_WHITE, true);
        GradientDrawable badgeBg = new GradientDrawable();
        badgeBg.setColor(0xD9101218);
        badgeBg.setCornerRadius(dp(5));
        badgeBg.setStroke(dp(1), 0x80FFFFFF);
        UiCompat.setBackground(demoBadge, badgeBg);
        demoBadge.setPadding(dp(5), dp(2), dp(5), dp(2));
        LayoutParams badgeLp =
                new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT);
        badgeLp.gravity = Gravity.TOP | Gravity.END;
        badgeLp.topMargin = dp(5);
        badgeLp.rightMargin = dp(5);
        posterWrap.addView(demoBadge, badgeLp);

        // Continue-watching progress bar when progress > 0.
        if (item.progress > 0f) {
            LinearLayout track = new LinearLayout(getContext());
            track.setOrientation(LinearLayout.HORIZONTAL);
            track.setBackgroundColor(0x66000000);
            View fill = new View(getContext());
            fill.setBackgroundColor(COLOR_ACCENT);
            track.addView(
                    fill,
                    new LinearLayout.LayoutParams(0, LayoutParams.MATCH_PARENT, item.progress));
            View rest = new View(getContext());
            track.addView(
                    rest,
                    new LinearLayout.LayoutParams(
                            0, LayoutParams.MATCH_PARENT, 1f - item.progress));
            LayoutParams trackLp = new LayoutParams(LayoutParams.MATCH_PARENT, dp(4));
            trackLp.gravity = Gravity.BOTTOM;
            posterWrap.addView(track, trackLp);
        }

        card.addView(posterWrap, new LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, posterH));

        TextView title = makeText(item.title(zh), 11, COLOR_WHITE, true);
        title.setSingleLine(true);
        LinearLayout.LayoutParams titleLp =
                new LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT);
        titleLp.topMargin = dp(5);
        card.addView(title, titleLp);

        // Compact pill-styled text-only spec badges per motion-tokens.json.
        if (!item.specs.isEmpty()) {
            LinearLayout badgeRow = new LinearLayout(getContext());
            badgeRow.setOrientation(LinearLayout.HORIZONTAL);
            int maxSpecs = Math.min(item.specs.size(), 2);
            for (int i = 0; i < maxSpecs; i++) {
                TextView pill = makeSpecBadgePill(item.specs.get(i));
                LinearLayout.LayoutParams pLp =
                        new LinearLayout.LayoutParams(
                                LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT);
                if (i > 0) {
                    pLp.leftMargin = dp(4);
                }
                badgeRow.addView(pill, pLp);
            }
            LinearLayout.LayoutParams brLp =
                    new LinearLayout.LayoutParams(
                            LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT);
            brLp.topMargin = dp(4);
            card.addView(badgeRow, brLp);
        }

        if (tvMode) {
            card.setOnFocusChangeListener(
                    new OnFocusChangeListener() {
                        @Override
                        public void onFocusChange(View v, boolean hasFocus) {
                            styleCardContainer(card, hasFocus);
                            animateFocusScale(card, hasFocus);
                        }
                    });
        }
        return card;
    }

    private TextView makeSpecBadgePill(String spec) {
        boolean isGold = spec.contains("4K");
        boolean isPurple = spec.contains("DV") || spec.contains("ATMOS");
        int fill =
                controller.isReduceTransparency()
                        ? (isGold ? 0xEB3A2810 : (isPurple ? 0xEB261F42 : 0xEB122640))
                        : (isGold ? 0x2EFF9F0A : (isPurple ? 0x335E5CE6 : 0x2E0A84FF));
        int stroke = isGold ? 0x66FF9F0A : (isPurple ? 0x73BF5AF2 : 0x660A84FF);
        int text = isGold ? 0xFFFFB340 : (isPurple ? 0xFFE5C7FF : 0xFF64D2FF);

        TextView pill = makeText(spec, 9.5f, text, true);
        pill.setSingleLine(true);
        pill.setPadding(dp(5), dp(1.5f), dp(5), dp(1.5f));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(fill);
        bg.setCornerRadius(dp(5));
        bg.setStroke(dp(1), stroke);
        UiCompat.setBackground(pill, bg);
        return pill;
    }

    private View buildAct3Sync(boolean wide) {
        LinearLayout left =
                makeInfoColumn(
                        zh ? "第 3 幕 · 多端同步（WebDAV / 局域网）" : "Act 3 · Multi-Device Sync",
                        zh ? "历史、收藏与订阅跨端同步" : "Sync History, Favorites & Sources",
                        zh
                                ? "基于 marco-movie-sync v2 协议，支持自配 WebDAV 云盘与同一局域网点对点免云盘直连同步。隐私空间与网盘/Emby 登录凭据始终保持本机隔离。"
                                : "Powered by marco-movie-sync v2 with both self-hosted WebDAV and cloud-free LAN peer-to-peer sync. Privacy space and netdisk/Emby credentials remain strictly device-local.");

        TextView syncBtn = makeActionPill(zh ? "配置同步" : "Configure Sync", false);
        syncBtn.setId(UiCompat.generateViewId());
        syncBtn.setOnClickListener(
                new OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        if (callbacks != null) {
                            callbacks.onOpenSync();
                        }
                    }
                });
        primaryCtaButton = syncBtn;
        LinearLayout.LayoutParams btnLp =
                new LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT);
        btnLp.topMargin = dp(16);
        left.addView(syncBtn, btnLp);

        LinearLayout right = makeGlassCard();
        right.addView(
                makeSyncPathRow(
                        zh ? "自配 WebDAV 云盘" : "Self-Hosted WebDAV",
                        zh
                                ? "自动双向合并观看历史、收藏与公开订阅"
                                : "Two-way merge for history, favorites & public subscriptions",
                        COLOR_ACCENT));
        LinearLayout lanRow =
                makeSyncPathRow(
                        zh ? "局域网点对点直连" : "LAN Peer-to-Peer Direct",
                        zh
                                ? "同一 Wi-Fi / 局域网免云盘一键互传，零第三方中转"
                                : "Same-network direct transfer with zero cloud relay",
                        COLOR_TEAL);
        LinearLayout.LayoutParams lanLp =
                new LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT);
        lanLp.topMargin = dp(10);
        right.addView(lanRow, lanLp);

        TextView isolationNote =
                makeText(
                        zh
                                ? "安全边界：隐私空间密码与网盘/Emby 凭据永不上传"
                                : "Privacy boundary: Privacy space & netdisk/Emby credentials never sync",
                        12,
                        COLOR_PURPLE,
                        true);
        LinearLayout.LayoutParams isoLp =
                new LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT);
        isoLp.topMargin = dp(12);
        right.addView(isolationNote, isoLp);

        return assembleSplit(wide, left, right);
    }

    private LinearLayout makeSyncPathRow(String title, String desc, int accent) {
        LinearLayout row = new LinearLayout(getContext());
        row.setOrientation(LinearLayout.VERTICAL);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(0x5509090C);
        bg.setCornerRadius(dp(12));
        bg.setStroke(dp(1), (accent & 0x00FFFFFF) | 0x66000000);
        UiCompat.setBackground(row, bg);
        row.setPadding(dp(14), dp(12), dp(14), dp(12));
        row.addView(makeText(title, 14, accent, true));
        TextView d = makeText(desc, 12, COLOR_MUTED, false);
        LinearLayout.LayoutParams lp =
                new LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(4);
        row.addView(d, lp);
        return row;
    }

    private View buildAct4PlaybackHud(boolean wide) {
        String body =
                tvMode
                        ? (zh
                                ? "遥控器短按左右键快进/快退 15 秒，长按左右键加速预览并松手即播，返回键随时取消。支持起播规格提示、常驻细进度条、3 秒跳过片头倒计时与分片弹幕。"
                                : "Short press Left/Right for 15s seek, hold Left/Right for accelerated scrub preview (release to play, Back to cancel). Includes start spec banner, thin progress bar, 3s skip countdown, and windowed danmaku.")
                        : (zh
                                ? "触控长按 2.0× 倍速，左右滑动在 1.25×–3.0× 间调速，上滑即可锁定倍速；两侧双击快进/快退，左右半屏上下滑动调亮度与音量。"
                                : "Hold for 2.0× speed, slide horizontally across 1.25×–3.0×, and swipe up to lock speed. Double-tap sides to seek; swipe vertically on left/right edges for brightness and volume.");

        LinearLayout left =
                makeInfoColumn(
                        zh ? "第 4 幕 · 进阶播放操控与 HUD" : "Act 4 · Playback Controls & HUD",
                        tvMode
                                ? (zh ? "遥控长按预览与清晰大屏 HUD" : "Remote Scrub Preview & Big-Screen HUD")
                                : (zh
                                        ? "长按倍速、滑动调速与上滑锁定"
                                        : "Hold Speed, Slide Adjust & Swipe-Up Lock"),
                        body);

        int step = controller.getHudDemoStep();
        String[] touchStates =
                zh
                        ? new String[] {
                            "状态 1/3：长按触发 2.0× 临时倍速",
                            "状态 2/3：左右滑调速（1.25× / 1.5× / 2.0× / 3.0×）",
                            "状态 3/3：🔒 2.0× 锁定中 · 点击胶囊恢复",
                        }
                        : new String[] {
                            "Step 1/3: Hold for 2.0× boost",
                            "Step 2/3: Slide horizontally (1.25×–3.0×)",
                            "Step 3/3: 🔒 2.0× Locked · Tap pill to reset",
                        };
        String[] tvStates =
                zh
                        ? new String[] {
                            "状态 1/3：短按 ← / → 快进快退 15 秒",
                            "状态 2/3：长按 ← / → 加速预览，松手即播",
                            "状态 3/3：按返回键取消预览，恢复原位置",
                        }
                        : new String[] {
                            "Step 1/3: Short Left/Right seeks 15s",
                            "Step 2/3: Hold Left/Right scrubs, release to play",
                            "Step 3/3: Press Back to cancel & restore",
                        };
        String activeStateText = (tvMode ? tvStates : touchStates)[step % 3];

        // Component-level mock player HUD preview frame.
        LinearLayout right = makeGlassCard();
        FrameLayout mockScreen = new FrameLayout(getContext());
        GradientDrawable screenBg =
                new GradientDrawable(
                        GradientDrawable.Orientation.TL_BR,
                        new int[] {0xFF0C1222, 0xFF162238, 0xFF0A0D14});
        screenBg.setCornerRadius(dp(12));
        screenBg.setStroke(dp(1), COLOR_BORDER);
        UiCompat.setBackground(mockScreen, screenBg);
        mockScreen.setPadding(dp(12), dp(10), dp(12), dp(10));

        // Top-left StartSpecOverlay pill
        LinearLayout topSpecRow = new LinearLayout(getContext());
        topSpecRow.setOrientation(LinearLayout.HORIZONTAL);
        topSpecRow.addView(makeSpecBadgePill("4K"));
        TextView dvPill = makeSpecBadgePill("DV · ATMOS");
        LinearLayout.LayoutParams dvLp =
                new LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT);
        dvLp.leftMargin = dp(5);
        topSpecRow.addView(dvPill, dvLp);
        LayoutParams topSpecLp =
                new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT);
        topSpecLp.gravity = Gravity.TOP | Gravity.START;
        mockScreen.addView(topSpecRow, topSpecLp);

        // Floating danmaku lane preview
        TextView danmakuPill =
                makeText(
                        zh ? "弹幕示例 · 画面细节很清晰" : "Sample Danmaku · Crisp cinema detail",
                        11,
                        0xDDFFFFFF,
                        false);
        LayoutParams dmLp = new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT);
        dmLp.gravity = Gravity.TOP | Gravity.END;
        dmLp.topMargin = dp(26);
        mockScreen.addView(danmakuPill, dmLp);

        // Center active gesture/remote state pill
        TextView stateCapsule = makeText(activeStateText, 12, COLOR_WHITE, true);
        GradientDrawable capBg = new GradientDrawable();
        capBg.setColor(0xD9101626);
        capBg.setCornerRadius(dp(16));
        capBg.setStroke(dp(1), COLOR_ACCENT);
        UiCompat.setBackground(stateCapsule, capBg);
        stateCapsule.setPadding(dp(12), dp(6), dp(12), dp(6));
        LayoutParams capLp = new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT);
        capLp.gravity = Gravity.CENTER;
        mockScreen.addView(stateCapsule, capLp);

        // Bottom-right 3s skip-intro countdown pill
        TextView skipIntroPill =
                makeText(zh ? "3s 跳过片头" : "Skip Intro 3s", 10.5f, COLOR_GOLD, true);
        GradientDrawable skipBg = new GradientDrawable();
        skipBg.setColor(0xD9241B10);
        skipBg.setCornerRadius(dp(12));
        skipBg.setStroke(dp(1), 0x88FF9F0A);
        UiCompat.setBackground(skipIntroPill, skipBg);
        skipIntroPill.setPadding(dp(8), dp(3), dp(8), dp(3));
        LayoutParams siLp = new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT);
        siLp.gravity = Gravity.BOTTOM | Gravity.END;
        siLp.bottomMargin = dp(12);
        mockScreen.addView(skipIntroPill, siLp);

        // Bottom persistent thin progress bar
        float progressRatio = step == 0 ? 0.35f : (step == 1 ? 0.58f : 0.72f);
        LinearLayout barTrack = new LinearLayout(getContext());
        barTrack.setOrientation(LinearLayout.HORIZONTAL);
        barTrack.setBackgroundColor(0x44FFFFFF);
        View barFill = new View(getContext());
        barFill.setBackgroundColor(COLOR_ACCENT);
        barTrack.addView(
                barFill,
                new LinearLayout.LayoutParams(0, LayoutParams.MATCH_PARENT, progressRatio));
        barTrack.addView(
                new View(getContext()),
                new LinearLayout.LayoutParams(0, LayoutParams.MATCH_PARENT, 1f - progressRatio));
        LayoutParams barLp = new LayoutParams(LayoutParams.MATCH_PARENT, dp(4));
        barLp.gravity = Gravity.BOTTOM;
        mockScreen.addView(barTrack, barLp);

        right.addView(
                mockScreen, new LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, dp(164)));

        // Interactive cycle button (clickable & TV focusable) to step through HUD gesture states.
        TextView cycleBtn =
                makeActionPill(
                        zh
                                ? "切换操控演示状态 (" + (step + 1) + "/3)"
                                : "Cycle Control Demo (" + (step + 1) + "/3)",
                        false);
        cycleBtn.setTag(FOCUS_TAG_HUD_STEP);
        cycleBtn.setId(UiCompat.generateViewId());
        cycleBtn.setOnClickListener(
                new OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        controller.cycleHudDemoStep();
                        renderAct(FOCUS_TAG_HUD_STEP);
                    }
                });
        LinearLayout.LayoutParams cyLp =
                new LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT);
        cyLp.topMargin = dp(12);
        right.addView(cycleBtn, cyLp);

        return assembleSplit(wide, left, right);
    }

    private View buildAct5Personalize(boolean wide) {
        LinearLayout left =
                makeInfoColumn(
                        zh ? "第 5 幕 · 个性化外观与立即开始" : "Act 5 · Personalize & Launch",
                        zh ? "按您的观看习惯微调界面" : "Tailor Comfort & Visuals",
                        zh
                                ? "可在此快速预览减少动态效果、降低透明度与界面缩放（100% / 110% / 120%），稍后也可随时在「设置 -> 关于与帮助 -> 重新查看新手引导」再次打开。"
                                : "Preview Reduce Motion, Reduce Transparency, and UI Scale (100% / 110% / 120%). Replay this guide anytime in Settings -> About & Help.");

        LinearLayout ctaRow = new LinearLayout(getContext());
        ctaRow.setOrientation(LinearLayout.HORIZONTAL);
        ctaRow.setClipChildren(false);
        ctaRow.setClipToPadding(false);
        TextView importNow = makeActionPill(zh ? "立即导入配置" : "Import Config Now", true);
        importNow.setId(UiCompat.generateViewId());
        importNow.setOnClickListener(
                new OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        controller.complete(false);
                        if (callbacks != null) {
                            callbacks.onFinished(false);
                            callbacks.onImportConfig("");
                        }
                    }
                });
        primaryCtaButton = importNow;
        ctaRow.addView(importNow);

        LinearLayout.LayoutParams ctaLp =
                new LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT);
        ctaLp.topMargin = dp(16);
        left.addView(ctaRow, ctaLp);

        LinearLayout right = makeGlassCard();
        right.setClipChildren(false);
        right.setClipToPadding(false);

        LinearLayout motionRow =
                makeToggleRow(
                        zh ? "减少动态效果" : "Reduce Motion",
                        controller.isReduceMotion(),
                        FOCUS_TAG_REDUCE_MOTION,
                        new OnClickListener() {
                            @Override
                            public void onClick(View v) {
                                controller.setReduceMotion(!controller.isReduceMotion());
                                notifyPersonalization();
                                renderAct(FOCUS_TAG_REDUCE_MOTION);
                            }
                        });
        right.addView(motionRow);

        LinearLayout transRow =
                makeToggleRow(
                        zh ? "降低透明度（高对比纯色）" : "Reduce Transparency",
                        controller.isReduceTransparency(),
                        FOCUS_TAG_REDUCE_TRANS,
                        new OnClickListener() {
                            @Override
                            public void onClick(View v) {
                                controller.setReduceTransparency(
                                        !controller.isReduceTransparency());
                                notifyPersonalization();
                                renderAct(FOCUS_TAG_REDUCE_TRANS);
                            }
                        });
        LinearLayout.LayoutParams tLp =
                new LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT);
        tLp.topMargin = dp(10);
        right.addView(transRow, tLp);

        TextView scaleHeader = makeText(zh ? "界面缩放" : "UI Scale", 13, COLOR_MUTED, true);
        LinearLayout.LayoutParams shLp =
                new LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT);
        shLp.topMargin = dp(14);
        right.addView(scaleHeader, shLp);

        LinearLayout scaleRow = new LinearLayout(getContext());
        scaleRow.setOrientation(LinearLayout.HORIZONTAL);
        scaleRow.setClipChildren(false);
        scaleRow.setClipToPadding(false);
        for (int i = 0; i < SUPPORTED_UI_SCALES.length; i++) {
            final int pct = SUPPORTED_UI_SCALES[i];
            final String tag = FOCUS_TAG_SCALE_PREFIX + pct;
            boolean selected = controller.getUiScalePercent() == pct;
            TextView chip = makeActionPill(pct + "%", selected);
            chip.setTag(tag);
            chip.setOnClickListener(
                    new OnClickListener() {
                        @Override
                        public void onClick(View v) {
                            controller.setUiScalePercent(pct);
                            notifyPersonalization();
                            renderAct(tag);
                        }
                    });
            LinearLayout.LayoutParams cLp =
                    new LinearLayout.LayoutParams(
                            LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT);
            if (i > 0) {
                cLp.leftMargin = dp(8);
            }
            scaleRow.addView(chip, cLp);
        }
        LinearLayout.LayoutParams srLp =
                new LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT);
        srLp.topMargin = dp(8);
        right.addView(scaleRow, srLp);

        return assembleSplit(wide, left, right);
    }

    private void notifyPersonalization() {
        if (callbacks != null) {
            callbacks.onPersonalizationChanged(
                    controller.isReduceMotion(),
                    controller.isReduceTransparency(),
                    controller.getUiScalePercent());
        }
    }

    private LinearLayout makeToggleRow(
            String label, final boolean enabled, String focusTag, OnClickListener listener) {
        final LinearLayout row = new LinearLayout(getContext());
        row.setTag(focusTag);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setFocusable(true);
        row.setClickable(true);
        row.setOnClickListener(listener);
        row.setPadding(dp(14), dp(12), dp(14), dp(12));

        final TextView title = makeText(label, 14, COLOR_WHITE, false);
        row.addView(title, new LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f));

        final TextView state =
                makeText(
                        enabled ? (zh ? "已开启" : "ON") : (zh ? "已关闭" : "OFF"),
                        12,
                        enabled ? COLOR_TEAL : COLOR_MUTED,
                        true);
        row.addView(state);

        styleToggleRow(row, title, state, enabled, false);
        row.setOnFocusChangeListener(
                new OnFocusChangeListener() {
                    @Override
                    public void onFocusChange(View v, boolean hasFocus) {
                        styleToggleRow(row, title, state, enabled, hasFocus);
                        animateFocusScale(row, hasFocus);
                    }
                });
        return row;
    }

    private void styleToggleRow(
            LinearLayout row, TextView title, TextView state, boolean enabled, boolean focused) {
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(dp(12));
        if (focused) {
            bg.setColor(COLOR_WHITE);
            bg.setStroke(dp(2), COLOR_WHITE);
            title.setTextColor(COLOR_FOCUS_TEXT);
            state.setTextColor(COLOR_ACCENT);
        } else {
            bg.setColor(controller.isReduceTransparency() ? 0xE6141418 : 0x5509090C);
            bg.setStroke(dp(1), enabled ? COLOR_ACCENT : COLOR_BORDER);
            title.setTextColor(COLOR_WHITE);
            state.setTextColor(enabled ? COLOR_TEAL : COLOR_MUTED);
        }
        UiCompat.setBackground(row, bg);
    }

    private void styleCardContainer(LinearLayout card, boolean focused) {
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(dp(10));
        if (focused) {
            bg.setColor(0x33F5F5F7);
            bg.setStroke(dp(2), COLOR_WHITE);
        } else {
            bg.setColor(0x2209090C);
            bg.setStroke(dp(1), 0x1FFFFFFF);
        }
        UiCompat.setBackground(card, bg);
    }

    private View assembleSplit(boolean wide, View left, View right) {
        LinearLayout container = new LinearLayout(getContext());
        container.setOrientation(wide ? LinearLayout.HORIZONTAL : LinearLayout.VERTICAL);
        container.setGravity(wide ? Gravity.CENTER_VERTICAL : Gravity.TOP);
        container.setClipChildren(false);
        container.setClipToPadding(false);
        if (wide) {
            LinearLayout.LayoutParams leftLp =
                    new LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 0.9f);
            leftLp.rightMargin = dp(24);
            container.addView(left, leftLp);
            container.addView(
                    right, new LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1.1f));
        } else {
            container.addView(
                    left,
                    new LinearLayout.LayoutParams(
                            LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT));
            LinearLayout.LayoutParams rightLp =
                    new LinearLayout.LayoutParams(
                            LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT);
            rightLp.topMargin = dp(16);
            container.addView(right, rightLp);
        }
        return container;
    }

    private LinearLayout makeInfoColumn(String eyebrow, String headline, String body) {
        LinearLayout col = new LinearLayout(getContext());
        col.setOrientation(LinearLayout.VERTICAL);
        col.setClipChildren(false);
        col.setClipToPadding(false);
        col.addView(makeText(eyebrow, 13, COLOR_TEAL, true));

        TextView h = makeText(headline, tvMode ? 28 : 24, COLOR_WHITE, true);
        LinearLayout.LayoutParams hLp =
                new LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT);
        hLp.topMargin = dp(8);
        col.addView(h, hLp);

        TextView b = makeText(body, tvMode ? 16 : 14, COLOR_MUTED, false);
        b.setLineSpacing(dp(4), 1.0f);
        LinearLayout.LayoutParams bLp =
                new LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT);
        bLp.topMargin = dp(10);
        col.addView(b, bLp);
        return col;
    }

    private LinearLayout makeGlassCard() {
        LinearLayout card = new LinearLayout(getContext());
        card.setOrientation(LinearLayout.VERTICAL);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(controller.isReduceTransparency() ? COLOR_CARD_SOLID : COLOR_CARD_GLASS);
        bg.setCornerRadius(dp(18));
        bg.setStroke(dp(1), controller.isReduceTransparency() ? COLOR_BORDER_HIGH : COLOR_BORDER);
        UiCompat.setBackground(card, bg);
        card.setPadding(dp(18), dp(16), dp(18), dp(16));
        return card;
    }

    private TextView makeActionPill(String label, boolean primary) {
        TextView btn = makeText(label, tvMode ? 15 : 14, COLOR_WHITE, true);
        btn.setGravity(Gravity.CENTER);
        btn.setFocusable(true);
        btn.setClickable(true);
        btn.setPadding(dp(18), dp(10), dp(18), dp(10));
        stylePill(btn, primary, false);
        attachPillFocusHighlight(btn, primary);
        return btn;
    }

    private void stylePill(TextView btn, boolean primary, boolean focused) {
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(dp(22));
        if (focused) {
            bg.setColor(COLOR_WHITE);
            bg.setStroke(dp(2), COLOR_WHITE);
            btn.setTextColor(COLOR_FOCUS_TEXT);
        } else if (primary) {
            bg.setColor(COLOR_ACCENT);
            bg.setStroke(dp(1), 0x44FFFFFF);
            btn.setTextColor(COLOR_WHITE);
        } else {
            bg.setColor(controller.isReduceTransparency() ? COLOR_CARD_SOLID : 0x33FFFFFF);
            bg.setStroke(dp(1), COLOR_BORDER);
            btn.setTextColor(COLOR_WHITE);
        }
        UiCompat.setBackground(btn, bg);
    }

    private void attachPillFocusHighlight(final TextView btn, final boolean primary) {
        btn.setOnFocusChangeListener(
                new OnFocusChangeListener() {
                    @Override
                    public void onFocusChange(View v, boolean hasFocus) {
                        stylePill(btn, primary, hasFocus);
                        animateFocusScale(btn, hasFocus);
                    }
                });
    }

    private void animateFocusScale(View view, boolean focused) {
        view.animate().cancel();
        if (controller.isReduceMotion()) {
            view.setScaleX(1.0f);
            view.setScaleY(1.0f);
            return;
        }
        float targetScale = focused ? 1.05f : 1.0f;
        if (Build.VERSION.SDK_INT >= 21) {
            view.animate()
                    .scaleX(targetScale)
                    .scaleY(targetScale)
                    .setDuration(210L)
                    .setInterpolator(new PathInterpolator(0.2f, 0.0f, 0.0f, 1.0f))
                    .start();
        } else {
            view.animate().scaleX(targetScale).scaleY(targetScale).setDuration(210L).start();
        }
    }

    private void applyRoundedClip(View view, final int radiusPx) {
        if (Build.VERSION.SDK_INT >= 21) {
            view.setOutlineProvider(
                    new ViewOutlineProvider() {
                        @Override
                        public void getOutline(View v, Outline outline) {
                            outline.setRoundRect(0, 0, v.getWidth(), v.getHeight(), radiusPx);
                        }
                    });
            UiCompat.setClipToOutline(view, true);
        }
    }

    private TextView makeText(String text, float sp, int color, boolean bold) {
        TextView tv = new TextView(getContext());
        float scale = controller.getUiScalePercent() / 100f;
        tv.setText(text);
        tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp * scale);
        tv.setTextColor(color);
        if (bold) {
            tv.setTypeface(Typeface.DEFAULT_BOLD);
        }
        return tv;
    }

    private boolean isWideLayout() {
        DisplayMetrics dm = getResources().getDisplayMetrics();
        float widthDp = dm.widthPixels / Math.max(1f, dm.density);
        return tvMode || widthDp >= 720f;
    }

    private int dp(float value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private static boolean isChineseLocale() {
        String lang = Locale.getDefault().getLanguage();
        return lang != null && lang.toLowerCase(Locale.US).startsWith("zh");
    }

    private Bitmap loadPosterBitmap(String file) {
        Bitmap cached = posterBitmaps.get(file);
        if (cached != null && !cached.isRecycled()) {
            return cached;
        }
        try {
            InputStream in = getContext().getAssets().open("demo/" + file);
            try {
                BitmapFactory.Options opts = new BitmapFactory.Options();
                opts.inSampleSize = 2; // 180x270 keeps all 14 posters under ~1.2MB RAM.
                Bitmap bmp = BitmapFactory.decodeStream(in, null, opts);
                if (bmp != null) {
                    posterBitmaps.put(file, bmp);
                }
                return bmp;
            } finally {
                in.close();
            }
        } catch (IOException ignored) {
            return null;
        }
    }

    /** Loads demo poster entries from {@code assets/demo/manifest.json} with safe empty fallback. */
    public static List<DemoItem> loadDemoItems(Context context) {
        if (context == null) {
            return Collections.emptyList();
        }
        AssetManager assets = context.getAssets();
        if (assets == null) {
            return Collections.emptyList();
        }
        try {
            InputStream in = assets.open("demo/manifest.json");
            try {
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buf = new byte[4096];
                int n;
                while ((n = in.read(buf)) > 0) {
                    out.write(buf, 0, n);
                }
                String raw = new String(out.toByteArray(), Charset.forName("UTF-8"));
                return parseManifest(raw);
            } finally {
                in.close();
            }
        } catch (IOException ignored) {
            return Collections.emptyList();
        }
    }

    /** Pure-Java manifest parser shared by runtime and JVM checks. */
    public static List<DemoItem> parseManifest(String rawJson) {
        if (rawJson == null || rawJson.trim().isEmpty()) {
            return Collections.emptyList();
        }
        try {
            JSONObject root = new JSONObject(rawJson);
            JSONArray arr = root.optJSONArray("items");
            if (arr == null) {
                return Collections.emptyList();
            }
            List<DemoItem> out = new ArrayList<DemoItem>(arr.length());
            for (int i = 0; i < arr.length(); i++) {
                JSONObject o = arr.optJSONObject(i);
                if (o == null) {
                    continue;
                }
                List<String> specs = new ArrayList<String>();
                JSONArray specArr = o.optJSONArray("specs");
                if (specArr != null) {
                    for (int s = 0; s < specArr.length(); s++) {
                        String tag = specArr.optString(s, "").trim();
                        if (!tag.isEmpty()) {
                            specs.add(tag);
                        }
                    }
                }
                int accent = parseHexColor(o.optString("accentHex", "#0A84FF"), COLOR_ACCENT);
                out.add(
                        new DemoItem(
                                o.optString("id", "demo_" + (i + 1)),
                                o.optString("file", ""),
                                o.optString("titleZh", "示例"),
                                o.optString("titleEn", "Sample"),
                                o.optString("badgeZh", "示例"),
                                o.optString("badgeEn", "DEMO"),
                                specs,
                                (float) o.optDouble("progress", 0.0),
                                accent));
            }
            return out;
        } catch (JSONException ignored) {
            return Collections.emptyList();
        }
    }

    private static int parseHexColor(String hex, int fallback) {
        if (hex == null) {
            return fallback;
        }
        String s = hex.trim();
        if (s.startsWith("#")) {
            s = s.substring(1);
        }
        if (s.length() == 6) {
            try {
                return 0xFF000000 | Integer.parseInt(s, 16);
            } catch (NumberFormatException ignored) {
                return fallback;
            }
        }
        return fallback;
    }
}
