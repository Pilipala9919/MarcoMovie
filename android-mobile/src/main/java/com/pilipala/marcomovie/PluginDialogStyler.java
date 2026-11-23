package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.StateListDrawable;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.text.TextUtils;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewTreeObserver;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.CheckedTextView;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.ScrollView;
import android.widget.TextView;
import java.lang.ref.WeakReference;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.WeakHashMap;

/**
 * Runtime iOS Liquid Glass theme and zero-overflow layout normalizer for third-party spider /
 * ConfigCenter dialogs (e.g. Pan.java LoginShow, QR scan dialogs, Cookie prompts, and netdisk
 * priority pickers). Styles Android host views without modifying or unwrapping any plugin binary,
 * and never mutates view tags.
 */
final class PluginDialogStyler {
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final Set<View> STYLED_DECORS =
            Collections.newSetFromMap(new WeakHashMap<View, Boolean>());
    private static final Set<View> STYLED_CARD_ROOTS =
            Collections.newSetFromMap(new WeakHashMap<View, Boolean>());
    private static final Set<View> STYLED_DRIVE_ROWS =
            Collections.newSetFromMap(new WeakHashMap<View, Boolean>());
    private static final Set<View> STYLED_BUTTON_ROWS =
            Collections.newSetFromMap(new WeakHashMap<View, Boolean>());
    private static final Set<View> STYLED_LIST_VIEWS =
            Collections.newSetFromMap(new WeakHashMap<View, Boolean>());
    private static final Set<View> STYLED_LIST_ITEMS =
            Collections.newSetFromMap(new WeakHashMap<View, Boolean>());
    private static final Set<View> AUTO_FORWARDED_DECORS =
            Collections.newSetFromMap(new WeakHashMap<View, Boolean>());
    private static final int[] WATCH_DELAYS_MS = {
        0, 40, 100, 180, 300, 480, 750, 1100, 1600, 2200, 3000, 4200, 5600
    };
    private static final long DIRECT_DRIVE_FORWARD_TTL_MS = 8000L;

    private static String pendingForwardDriveKey;
    private static boolean pendingForwardToggleEnable;
    private static long pendingForwardExpiresAtMs;
    private static WeakReference<View> pendingDismissIntermediateDecor;

    private PluginDialogStyler() {}

    static void armDirectDriveForward(
            final MainActivity a, final String driveKey, final boolean toggleEnableOnly) {
        if (driveKey == null || driveKey.trim().isEmpty()) {
            clearDirectDriveForward();
            return;
        }
        pendingForwardDriveKey = driveKey.trim().toLowerCase(Locale.ROOT);
        pendingForwardToggleEnable = toggleEnableOnly;
        pendingForwardExpiresAtMs = SystemClock.uptimeMillis() + DIRECT_DRIVE_FORWARD_TTL_MS;
        watch(a);
    }

    static void clearDirectDriveForward() {
        pendingForwardDriveKey = null;
        pendingForwardToggleEnable = false;
        pendingForwardExpiresAtMs = 0L;
    }

    static boolean shouldExpandToMatchParent(boolean inHScroll, boolean inHorizontalLinearLayout) {
        return !inHScroll && !inHorizontalLinearLayout;
    }

    static String detectDriveKeyFromLabel(String text) {
        if (text == null || text.trim().isEmpty()) return null;
        String raw = text.trim();
        String upper = raw.toUpperCase(Locale.ROOT);
        if (raw.contains("夸父") || raw.contains("夸克") || upper.contains("QUARK")) return "quark";
        if (raw.contains("优汐") || upper.contains("UC")) return "uc";
        if (raw.contains("嘟嘟") || raw.contains("百度") || upper.contains("BAIDU")) return "baidu";
        if (raw.contains("阿狸") || raw.contains("阿里") || upper.contains("ALI")) return "ali";
        if (raw.contains("115")) return "115";
        if (raw.contains("天翼") || raw.contains("189")) return "189";
        if (raw.contains("移动") || raw.contains("139")) return "139";
        if (raw.contains("123")) return "123";
        if (raw.contains("迅雷")) return "thunder";
        return null;
    }

    static boolean isDriveStatusToggleLabel(String text) {
        if (text == null || text.trim().isEmpty()) return false;
        String t = text.trim();
        return t.contains("启用中")
                || t.contains("已启用")
                || t.contains("未启用")
                || t.contains("已停用")
                || t.contains("停用")
                || "开启".equals(t)
                || "关闭".equals(t);
    }

    static boolean isDirectDriveLoginTarget(String targetDriveKey, String buttonText) {
        if (targetDriveKey == null || targetDriveKey.trim().isEmpty()) return false;
        String detected = detectDriveKeyFromLabel(buttonText);
        return targetDriveKey.trim().equalsIgnoreCase(detected)
                && !isDriveStatusToggleLabel(buttonText);
    }

    static void watch(final MainActivity a) {
        if (a == null) return;
        for (int delay : WATCH_DELAYS_MS) {
            MAIN.postDelayed(
                    () -> {
                        if (!a.isFinishing() && !a.isDestroyed()) {
                            scanAndStyleWindows(a);
                        }
                    },
                    delay);
        }
    }

    static void scanAndStyleWindows(final MainActivity a) {
        if (a == null || a.isFinishing() || a.isDestroyed()) return;
        try {
            if (pendingForwardDriveKey != null
                    && SystemClock.uptimeMillis() > pendingForwardExpiresAtMs) {
                clearDirectDriveForward();
            }
            View activityDecor = a.getWindow() != null ? a.getWindow().getDecorView() : null;
            List<View> views = getGlobalWindowViews();
            List<ViewGroup> pluginDecors = new ArrayList<>();
            List<ViewGroup> pluginContents = new ArrayList<>();
            for (View root : views) {
                if (root == null || root == activityDecor || !(root instanceof ViewGroup)) continue;
                if (isAppOwnedWindow(root)) continue;
                Context ctx = root.getContext();
                if (!belongsToApp(ctx, a)) continue;
                ViewGroup.LayoutParams rawLp = root.getLayoutParams();
                if (rawLp instanceof WindowManager.LayoutParams) {
                    WindowManager.LayoutParams wlp = (WindowManager.LayoutParams) rawLp;
                    if (wlp.type == WindowManager.LayoutParams.TYPE_TOAST) continue;
                    if ((wlp.flags & WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE) != 0) continue;
                }
                View content = root.findViewById(android.R.id.content);
                if (!(content instanceof ViewGroup) || ((ViewGroup) content).getChildCount() == 0) {
                    continue;
                }
                pluginDecors.add((ViewGroup) root);
                pluginContents.add((ViewGroup) content);
            }

            boolean hasNonForwardedPluginDialog = false;
            for (ViewGroup decor : pluginDecors) {
                if (!AUTO_FORWARDED_DECORS.contains(decor)) {
                    hasNonForwardedPluginDialog = true;
                    break;
                }
            }

            for (int i = 0; i < pluginDecors.size(); i++) {
                ViewGroup decor = pluginDecors.get(i);
                ViewGroup content = pluginContents.get(i);
                if (AUTO_FORWARDED_DECORS.contains(decor)) {
                    decor.setAlpha(0f);
                    if (!hasNonForwardedPluginDialog && decor.isAttachedToWindow()) {
                        dismissPluginDecor(decor, content);
                    }
                    continue;
                }
                if (containsQrImageView(a, content)) {
                    clearDirectDriveForward();
                    decor.setAlpha(1f);
                    stylePluginDecor(a, decor, content);
                    continue;
                }
                if (tryAutoForwardDriveDialog(a, decor, content)) {
                    continue;
                }
                decor.setAlpha(1f);
                stylePluginDecor(a, decor, content);
            }
        } catch (Throwable t) {
            AppLog.w("PluginDialogStyler", "scanAndStyleWindows skipped", t);
        }
    }

    private static boolean containsQrImageView(MainActivity a, View v) {
        if (v == null) return false;
        if (v instanceof ImageView) {
            ImageView iv = (ImageView) v;
            String resName = resourceEntryName(iv);
            if (!"icon".equals(resName) && iv.getId() != android.R.id.icon) {
                ViewGroup.LayoutParams lp = iv.getLayoutParams();
                int w = lp != null && lp.width > 0 ? lp.width : iv.getMeasuredWidth();
                int h = lp != null && lp.height > 0 ? lp.height : iv.getMeasuredHeight();
                boolean likelyQr =
                        (w >= a.dp(105) && h >= a.dp(105))
                                || (iv.getDrawable() != null
                                        && iv.getDrawable().getIntrinsicWidth() >= 130
                                        && Math.abs(
                                                        iv.getDrawable().getIntrinsicWidth()
                                                                - iv.getDrawable()
                                                                        .getIntrinsicHeight())
                                                <= 36);
                if (likelyQr) return true;
            }
        }
        if (v instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) v;
            for (int i = 0; i < vg.getChildCount(); i++) {
                if (containsQrImageView(a, vg.getChildAt(i))) return true;
            }
        }
        return false;
    }

    private static boolean tryAutoForwardDriveDialog(
            final MainActivity a, final ViewGroup decor, final ViewGroup content) {
        List<LinearLayout> driveRows = new ArrayList<>();
        collectSpiderDriveRows(content, driveRows, 0);
        if (driveRows.size() < 2) {
            return false;
        }
        // Always harvest live login & enabled statuses for Level-1 AccountPanel.
        for (LinearLayout row : driveRows) {
            harvestDriveRowStatus(a, row);
        }
        final String targetKey = pendingForwardDriveKey;
        if (targetKey == null) {
            return false;
        }
        final boolean toggleOnly = pendingForwardToggleEnable;
        final View targetBtn = findDriveActionView(driveRows, targetKey, toggleOnly);
        clearDirectDriveForward();
        if (targetBtn == null) {
            a.toast("当前片源未提供该网盘的快捷扫码入口，请在列表中选择");
            return false;
        }
        AUTO_FORWARDED_DECORS.add(decor);
        pendingDismissIntermediateDecor = new WeakReference<>(decor);
        decor.setAlpha(0f);
        if (Build.VERSION.SDK_INT >= 18) {
            decor.getViewTreeObserver()
                    .addOnWindowFocusChangeListener(
                            hasFocus -> {
                                if (hasFocus && AUTO_FORWARDED_DECORS.contains(decor)) {
                                    decor.setAlpha(0f);
                                    MAIN.post(() -> dismissPluginDecor(decor, content));
                                }
                            });
        }
        MAIN.post(
                () -> {
                    try {
                        if (!decor.isAttachedToWindow()) return;
                        targetBtn.performClick();
                        if (toggleOnly) {
                            MAIN.postDelayed(
                                    () -> {
                                        try {
                                            List<LinearLayout> refreshed = new ArrayList<>();
                                            collectSpiderDriveRows(content, refreshed, 0);
                                            for (LinearLayout row : refreshed) {
                                                harvestDriveRowStatus(a, row);
                                            }
                                            a.toast("已切换网盘启用状态");
                                            dismissPluginDecor(decor, content);
                                        } catch (Throwable ignored) {
                                        }
                                    },
                                    260);
                        } else {
                            watch(a);
                        }
                    } catch (Throwable t) {
                        AUTO_FORWARDED_DECORS.remove(decor);
                        decor.setAlpha(1f);
                        stylePluginDecor(a, decor, content);
                    }
                });
        return true;
    }

    private static void collectSpiderDriveRows(View v, List<LinearLayout> out, int depth) {
        if (v == null || depth > 14) return;
        if (v instanceof LinearLayout && isSpiderDriveRow((LinearLayout) v)) {
            out.add((LinearLayout) v);
            return;
        }
        if (v instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) v;
            for (int i = 0; i < vg.getChildCount(); i++) {
                collectSpiderDriveRows(vg.getChildAt(i), out, depth + 1);
            }
        }
    }

    private static void harvestDriveRowStatus(MainActivity a, LinearLayout row) {
        TextView accountView = null;
        TextView statusView = null;
        for (int i = 0; i < row.getChildCount(); i++) {
            View child = row.getChildAt(i);
            if (!(child instanceof TextView)) continue;
            String label = textOf((TextView) child);
            if (isDriveStatusToggleLabel(label)) {
                if (statusView == null) statusView = (TextView) child;
            } else if (detectDriveKeyFromLabel(label) != null || accountView == null) {
                accountView = (TextView) child;
            }
        }
        if (accountView != null) {
            AccountPanel.recordObservedSpiderRow(
                    a, textOf(accountView), statusView == null ? "" : textOf(statusView));
        }
    }

    private static View findDriveActionView(
            List<LinearLayout> driveRows, String targetDriveKey, boolean toggleOnly) {
        for (LinearLayout row : driveRows) {
            View accountBtn = null;
            View statusBtn = null;
            boolean rowMatchesDrive = false;
            for (int i = 0; i < row.getChildCount(); i++) {
                View child = row.getChildAt(i);
                if (!(child instanceof TextView)) continue;
                String label = textOf((TextView) child);
                if (isDirectDriveLoginTarget(targetDriveKey, label)) {
                    rowMatchesDrive = true;
                    accountBtn = child;
                } else if (isDriveStatusToggleLabel(label)) {
                    statusBtn = child;
                }
            }
            if (rowMatchesDrive) {
                if (toggleOnly) {
                    return statusBtn != null ? statusBtn : accountBtn;
                }
                return accountBtn;
            }
        }
        return null;
    }

    private static void dismissPluginDecor(ViewGroup decor, ViewGroup content) {
        if (decor == null || !decor.isAttachedToWindow()) return;
        try {
            View cancel = findDismissButton(content, 0);
            if (cancel != null && cancel.isClickable()) {
                cancel.performClick();
                return;
            }
            KeyEvent down = new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_BACK);
            KeyEvent up = new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_BACK);
            decor.dispatchKeyEvent(down);
            decor.dispatchKeyEvent(up);
        } catch (Throwable ignored) {
        }
    }

    private static View findDismissButton(View v, int depth) {
        if (v == null || depth > 12) return null;
        if (v instanceof Button && v.getVisibility() == View.VISIBLE) {
            int id = v.getId();
            String label = textOf((TextView) v);
            if (id == android.R.id.button2 || isCancelLabel(label)) {
                return v;
            }
        }
        if (v instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) v;
            for (int i = 0; i < vg.getChildCount(); i++) {
                View found = findDismissButton(vg.getChildAt(i), depth + 1);
                if (found != null) return found;
            }
        }
        return null;
    }

    private static boolean belongsToApp(Context ctx, MainActivity a) {
        if (ctx == null || a == null) return false;
        try {
            return a.getPackageName().equals(ctx.getPackageName());
        } catch (Throwable ignored) {
            return true;
        }
    }

    private static boolean isAppOwnedWindow(View decor) {
        Object tag = decor.getTag();
        if (isAppOwnedTagValue(tag)) {
            return true;
        }
        return containsAppOwnedMarker(decor, 0);
    }

    private static boolean isAppOwnedTagValue(Object tag) {
        return "app-dialog".equals(tag)
                || "source-picker".equals(tag)
                || "player-bubble".equals(tag)
                || "mobile-drawer".equals(tag)
                || "account-panel".equals(tag);
    }

    private static boolean containsAppOwnedMarker(View v, int depth) {
        if (v == null || depth > 8) return false;
        if (isAppOwnedTagValue(v.getTag())) {
            return true;
        }
        String className = v.getClass().getName();
        if (className.startsWith("com.pilipala.")) {
            return true;
        }
        if (v instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) v;
            int n = vg.getChildCount();
            for (int i = 0; i < n; i++) {
                if (containsAppOwnedMarker(vg.getChildAt(i), depth + 1)) return true;
            }
        }
        return false;
    }

    @SuppressWarnings("unchecked")
    private static List<View> getGlobalWindowViews() {
        if (Build.VERSION.SDK_INT >= 29) {
            try {
                Method m =
                        Class.forName("android.view.inspector.WindowInspector")
                                .getMethod("getGlobalWindowViews");
                Object res = m.invoke(null);
                if (res instanceof List) {
                    return new ArrayList<>((List<View>) res);
                }
            } catch (Throwable ignored) {
            }
        }
        try {
            Class<?> wmgClass = Class.forName("android.view.WindowManagerGlobal");
            Object wmg = wmgClass.getMethod("getInstance").invoke(null);
            Field viewsField = wmgClass.getDeclaredField("mViews");
            viewsField.setAccessible(true);
            Object raw = viewsField.get(wmg);
            if (raw instanceof List) {
                return new ArrayList<>((List<View>) raw);
            }
        } catch (Throwable ignored) {
        }
        return Collections.emptyList();
    }

    static int resolveDialogWidthPx(int winW, int marginH, int maxCap) {
        int safeWin = Math.max(240, winW);
        int bounded = safeWin - Math.max(0, marginH);
        return Math.max(200, Math.min(bounded, maxCap));
    }

    static int resolveMaxQrSizePx(int winH, int dpMin, int dpMax, boolean tv) {
        int ratio = Math.round(Math.max(1, winH) * (tv ? 0.27f : 0.30f));
        return Math.min(dpMax, Math.max(dpMin, ratio));
    }

    static void applyHorizontalMargins(
            ViewGroup.MarginLayoutParams mlp, int left, int top, int right, int bottom) {
        if (mlp == null) return;
        zeroRelativeMargins(mlp);
        mlp.setMargins(left, top, right, bottom);
        if (Build.VERSION.SDK_INT >= 17) {
            mlp.setMarginStart(left);
            mlp.setMarginEnd(right);
        }
    }

    private static void stylePluginDecor(
            final MainActivity a, final ViewGroup decor, final ViewGroup content) {
        try {
            final boolean firstPass = STYLED_DECORS.add(decor);
            DisplayMetrics dm = a.getResources().getDisplayMetrics();
            int winW = a.windowWidth() > 0 ? a.windowWidth() : dm.widthPixels;
            int winH = a.windowHeight() > 0 ? a.windowHeight() : dm.heightPixels;
            final boolean tv = a.isTvDevice();
            final int maxDialogWidth =
                    tv
                            ? resolveDialogWidthPx(winW, a.dp(88), a.dp(660))
                            : resolveDialogWidthPx(winW, a.dp(24), a.dp(408));

            decor.setBackground(new ColorDrawable(Color.TRANSPARENT));
            decor.setPadding(0, 0, 0, 0);
            decor.setMinimumWidth(0);
            decor.setMinimumHeight(0);
            adjustWindowLayoutParams(a, decor, maxDialogWidth, winH);

            if (firstPass) {
                if (Build.VERSION.SDK_INT >= 18) {
                    decor.getViewTreeObserver()
                            .addOnWindowFocusChangeListener(
                                    hasFocus -> {
                                        try {
                                            if (!hasFocus) watch(a);
                                            else styleHierarchyPass(a, decor, content, winH);
                                        } catch (Throwable ignored) {
                                        }
                                    });
                }
                decor.getViewTreeObserver()
                        .addOnPreDrawListener(
                                new ViewTreeObserver.OnPreDrawListener() {
                                    @Override
                                    public boolean onPreDraw() {
                                        try {
                                            if (!decor.isAttachedToWindow()) {
                                                decor.getViewTreeObserver()
                                                        .removeOnPreDrawListener(this);
                                                return true;
                                            }
                                            if (decor.getPaddingLeft() != 0
                                                    || decor.getPaddingRight() != 0) {
                                                decor.setPadding(0, 0, 0, 0);
                                            }
                                            refreshSpiderButtonStates(a, content);
                                        } catch (Throwable ignored) {
                                        }
                                        return true;
                                    }
                                });
            }

            styleHierarchyPass(a, decor, content, winH);
        } catch (Throwable t) {
            AppLog.w("PluginDialogStyler", "stylePluginDecor skipped", t);
        }
    }

    private static void adjustWindowLayoutParams(
            MainActivity a, ViewGroup decor, int targetWidth, int screenHeight) {
        try {
            ViewGroup.LayoutParams raw = decor.getLayoutParams();
            if (!(raw instanceof WindowManager.LayoutParams)) return;
            WindowManager.LayoutParams wlp = (WindowManager.LayoutParams) raw;
            boolean changed = false;
            if (wlp.width != targetWidth) {
                wlp.width = targetWidth;
                changed = true;
            }
            int maxHeight = Math.round(screenHeight * (a.isTvDevice() ? 0.88f : 0.84f));
            if (wlp.height > maxHeight) {
                wlp.height = maxHeight;
                changed = true;
            }
            if (wlp.gravity != Gravity.CENTER
                    || wlp.x != 0
                    || wlp.y != 0
                    || wlp.horizontalMargin != 0f) {
                wlp.gravity = Gravity.CENTER;
                wlp.x = 0;
                wlp.y = 0;
                wlp.horizontalMargin = 0f;
                changed = true;
            }
            if ((wlp.flags & WindowManager.LayoutParams.FLAG_DIM_BEHIND) == 0
                    || wlp.dimAmount < 0.58f) {
                wlp.flags |= WindowManager.LayoutParams.FLAG_DIM_BEHIND;
                wlp.dimAmount = 0.68f;
                changed = true;
            }
            if (changed) {
                WindowManager wm = (WindowManager) a.getSystemService(Context.WINDOW_SERVICE);
                if (wm != null) wm.updateViewLayout(decor, wlp);
                decor.requestLayout();
            }
        } catch (Throwable ignored) {
        }
    }

    private static void styleHierarchyPass(
            MainActivity a, ViewGroup decor, ViewGroup content, int winH) {
        // Strip OEM 9-patch backgrounds, inset paddings, and margins from content up to DecorView
        clearAncestorsUpToDecor(content, decor);

        View firstChild = content.getChildAt(0);
        if (!(firstChild instanceof ViewGroup)) return;
        ViewGroup cardRoot = (ViewGroup) firstChild;

        ViewGroup.LayoutParams cardLp = cardRoot.getLayoutParams();
        if (cardLp != null) {
            boolean lpDirty = false;
            if (cardLp.width != ViewGroup.LayoutParams.MATCH_PARENT) {
                cardLp.width = ViewGroup.LayoutParams.MATCH_PARENT;
                lpDirty = true;
            }
            if (cardLp instanceof ViewGroup.MarginLayoutParams) {
                ViewGroup.MarginLayoutParams mlp = (ViewGroup.MarginLayoutParams) cardLp;
                if (mlp.leftMargin != 0
                        || mlp.rightMargin != 0
                        || mlp.topMargin != 0
                        || mlp.bottomMargin != 0) {
                    mlp.setMargins(0, 0, 0, 0);
                    zeroRelativeMargins(mlp);
                    lpDirty = true;
                }
            }
            if (lpDirty) cardRoot.setLayoutParams(cardLp);
        }

        if (STYLED_CARD_ROOTS.add(cardRoot)) {
            // Match iOS AppleGlassSurface obsidian-slate palette (#242429 -> #16161B)
            GradientDrawable glassCard =
                    new GradientDrawable(
                            GradientDrawable.Orientation.TOP_BOTTOM,
                            new int[] {0xf524242a, 0xf816161b});
            glassCard.setCornerRadius(a.dp(24));
            glassCard.setStroke(Math.max(1, a.dp(0.9f)), 0x34ffffff);
            cardRoot.setBackground(glassCard);
            boolean tv = a.isTvDevice();
            cardRoot.setPadding(
                    a.dp(tv ? 20 : 16), a.dp(tv ? 16 : 16), a.dp(tv ? 20 : 16), a.dp(tv ? 14 : 14));
            cardRoot.setMinimumWidth(0);
            cardRoot.setClipToPadding(true);
        }

        styleSubtree(a, cardRoot, cardRoot, winH, 0);
        styleAlertButtonBar(a, cardRoot);
        cardRoot.requestLayout();
    }

    private static void clearAncestorsUpToDecor(View start, View stop) {
        View cur = start;
        while (cur != null) {
            cur.setBackground(new ColorDrawable(Color.TRANSPARENT));
            if (cur.getPaddingLeft() != 0
                    || cur.getPaddingTop() != 0
                    || cur.getPaddingRight() != 0
                    || cur.getPaddingBottom() != 0) {
                cur.setPadding(0, 0, 0, 0);
            }
            ViewGroup.LayoutParams lp = cur.getLayoutParams();
            if (cur != stop && lp != null) {
                boolean changed = false;
                if (lp.width > 0) {
                    lp.width = ViewGroup.LayoutParams.MATCH_PARENT;
                    changed = true;
                }
                if (lp instanceof ViewGroup.MarginLayoutParams) {
                    ViewGroup.MarginLayoutParams mlp = (ViewGroup.MarginLayoutParams) lp;
                    if (mlp.leftMargin != 0
                            || mlp.rightMargin != 0
                            || mlp.topMargin != 0
                            || mlp.bottomMargin != 0) {
                        mlp.setMargins(0, 0, 0, 0);
                        zeroRelativeMargins(mlp);
                        changed = true;
                    }
                }
                if (changed) cur.setLayoutParams(lp);
            }
            if (cur == stop || !(cur.getParent() instanceof View)) break;
            cur = (View) cur.getParent();
        }
    }

    private static void zeroRelativeMargins(ViewGroup.MarginLayoutParams mlp) {
        if (Build.VERSION.SDK_INT >= 17) {
            mlp.setMarginStart(0);
            mlp.setMarginEnd(0);
        }
    }

    private static void styleSubtree(
            final MainActivity a,
            final View v,
            final ViewGroup cardRoot,
            final int winH,
            final int depth) {
        if (v == null || depth > 16) return;

        String resName = resourceEntryName(v);
        if ("titleDividerNoCustom".equals(resName)
                || "titleDivider".equals(resName)
                || "scrollIndicatorUp".equals(resName)
                || "scrollIndicatorDown".equals(resName)
                || "textSpacerNoButtons".equals(resName)
                || "textSpacerNoTitle".equals(resName)) {
            v.setVisibility(View.GONE);
            return;
        }

        boolean inHScroll = v.getParent() instanceof HorizontalScrollView;
        boolean inHorizontalRow =
                v.getParent() instanceof LinearLayout
                        && ((LinearLayout) v.getParent()).getOrientation()
                                == LinearLayout.HORIZONTAL;

        // Detect Pan.java LoginShow row: Horizontal LinearLayout containing account + status toggle
        if (v instanceof LinearLayout && isSpiderDriveRow((LinearLayout) v)) {
            styleSpiderDriveRow(a, (LinearLayout) v);
            return;
        }

        // Detect generic horizontal button row inside spider custom layouts (e.g. [取消] or QR
        // actions)
        if (v != cardRoot
                && v instanceof LinearLayout
                && !"buttonPanel".equals(resName)
                && isPluginHorizontalButtonBar((LinearLayout) v)) {
            stylePluginHorizontalButtonBar(a, (LinearLayout) v);
            return;
        }

        // Detect any other horizontal multi-child LinearLayout (e.g. [Label][Button][Button]) and
        // constrain child widths proportionally so no button can ever overflow past cardRoot's edge
        if (v != cardRoot
                && v instanceof LinearLayout
                && !"buttonPanel".equals(resName)
                && ((LinearLayout) v).getOrientation() == LinearLayout.HORIZONTAL
                && ((LinearLayout) v).getChildCount() >= 2
                && !inHScroll) {
            normalizeHorizontalOverflowRow(a, (LinearLayout) v);
        }

        // Normalize all intermediate ViewGroups so hardcoded widths (e.g. 500dp) or OEM AlertDialog
        // 24dp panel paddings never push child buttons past cardRoot's right edge
        if (v != cardRoot
                && v instanceof ViewGroup
                && shouldExpandToMatchParent(inHScroll, inHorizontalRow)) {
            ViewGroup.LayoutParams lp = v.getLayoutParams();
            if (lp != null) {
                boolean changed = false;
                boolean shouldFillWidth =
                        lp.width > 0
                                || v instanceof ScrollView
                                || v instanceof FrameLayout
                                || v instanceof ListView
                                || (v instanceof LinearLayout
                                        && ((LinearLayout) v).getOrientation()
                                                == LinearLayout.VERTICAL)
                                || isFrameworkPanelName(resName);
                if (shouldFillWidth && lp.width != ViewGroup.LayoutParams.MATCH_PARENT) {
                    lp.width = ViewGroup.LayoutParams.MATCH_PARENT;
                    changed = true;
                }
                if (lp instanceof ViewGroup.MarginLayoutParams) {
                    ViewGroup.MarginLayoutParams mlp = (ViewGroup.MarginLayoutParams) lp;
                    if (mlp.leftMargin != 0 || mlp.rightMargin != 0) {
                        mlp.leftMargin = 0;
                        mlp.rightMargin = 0;
                        zeroRelativeMargins(mlp);
                        changed = true;
                    }
                }
                if (changed) v.setLayoutParams(lp);
            }
            v.setMinimumWidth(0);
            if (isFrameworkPanelName(resName)) {
                v.setMinimumHeight(0);
            }
            if (!(v instanceof ListView)) {
                if (v.getBackground() != null) {
                    v.setBackgroundColor(Color.TRANSPARENT);
                }
                if (v.getPaddingLeft() != 0 || v.getPaddingRight() != 0) {
                    int topP = Math.min(v.getPaddingTop(), a.dp(4));
                    int botP = Math.min(v.getPaddingBottom(), a.dp(4));
                    v.setPadding(0, topP, 0, botP);
                }
                if (v instanceof ScrollView) {
                    ((ScrollView) v).setVerticalScrollBarEnabled(false);
                }
            }
        }

        if (v instanceof ListView) {
            styleListView(a, (ListView) v);
            return;
        }

        if (v instanceof ImageView) {
            styleQrOrIconImageView(a, (ImageView) v, resName, winH);
            return;
        }

        if (v instanceof EditText) {
            styleEditText(a, (EditText) v, inHScroll, inHorizontalRow);
            return;
        }

        if (v instanceof Button) {
            styleGenericPluginButton(a, (Button) v, inHScroll, inHorizontalRow);
            return;
        }

        if (v instanceof TextView) {
            stylePluginTextView(a, (TextView) v, resName, inHScroll, inHorizontalRow);
            return;
        }

        if (v instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) v;
            for (int i = 0; i < vg.getChildCount(); i++) {
                styleSubtree(a, vg.getChildAt(i), cardRoot, winH, depth + 1);
            }
        }
    }

    private static boolean isFrameworkPanelName(String resName) {
        return "parentPanel".equals(resName)
                || "topPanel".equals(resName)
                || "title_template".equals(resName)
                || "contentPanel".equals(resName)
                || "scrollView".equals(resName)
                || "customPanel".equals(resName)
                || "custom".equals(resName)
                || "buttonPanel".equals(resName);
    }

    private static boolean isSpiderDriveRow(LinearLayout row) {
        if (row.getOrientation() != LinearLayout.HORIZONTAL) return false;
        int count = row.getChildCount();
        if (count < 2 || count > 3) return false;
        boolean hasDriveLabel = false;
        boolean hasStatusOrButton = false;
        for (int i = 0; i < count; i++) {
            View child = row.getChildAt(i);
            if (child instanceof TextView) {
                String t = textOf((TextView) child);
                if (detectDriveKeyFromLabel(t) != null || t.contains("登录")) {
                    hasDriveLabel = true;
                }
                if (isDriveStatusToggleLabel(t) || child instanceof Button) {
                    hasStatusOrButton = true;
                }
            } else if (!(child instanceof ImageView)) {
                return false;
            }
        }
        return hasDriveLabel && hasStatusOrButton;
    }

    private static void normalizeHorizontalOverflowRow(MainActivity a, LinearLayout row) {
        row.setMinimumWidth(0);
        row.setWeightSum(-1f);
        ViewGroup.LayoutParams rawLp = row.getLayoutParams();
        if (rawLp != null) {
            rawLp.width = ViewGroup.LayoutParams.MATCH_PARENT;
            if (rawLp instanceof ViewGroup.MarginLayoutParams) {
                ViewGroup.MarginLayoutParams mlp = (ViewGroup.MarginLayoutParams) rawLp;
                applyHorizontalMargins(mlp, 0, mlp.topMargin, 0, mlp.bottomMargin);
            }
            row.setLayoutParams(rawLp);
        }
        List<View> visible = new ArrayList<>();
        for (int i = 0; i < row.getChildCount(); i++) {
            View c = row.getChildAt(i);
            if (c.getVisibility() != View.GONE) visible.add(c);
        }
        if (visible.size() < 2) return;
        int gap = a.dp(8);
        for (int i = 0; i < visible.size(); i++) {
            View c = visible.get(i);
            c.setMinimumWidth(0);
            if (c instanceof TextView) {
                ((TextView) c).setMinWidth(0);
                ((TextView) c).setSingleLine(true);
                ((TextView) c).setEllipsize(TextUtils.TruncateAt.END);
            }
            if (c.getLayoutParams() instanceof LinearLayout.LayoutParams) {
                LinearLayout.LayoutParams clp = (LinearLayout.LayoutParams) c.getLayoutParams();
                if (c instanceof ImageView) {
                    clp.weight = 0f;
                } else {
                    clp.width = 0;
                    clp.weight = 1f;
                }
                applyHorizontalMargins(
                        clp, 0, clp.topMargin, i < visible.size() - 1 ? gap : 0, clp.bottomMargin);
                c.setLayoutParams(clp);
            }
        }
    }

    private static boolean isPluginHorizontalButtonBar(LinearLayout row) {
        if (row.getOrientation() != LinearLayout.HORIZONTAL) return false;
        int n = row.getChildCount();
        if (n == 0 || n > 5) return false;
        int btnCount = 0;
        for (int i = 0; i < n; i++) {
            View c = row.getChildAt(i);
            int id = c.getId();
            if (id == android.R.id.button1
                    || id == android.R.id.button2
                    || id == android.R.id.button3) {
                return false;
            }
            if (c instanceof Button) {
                btnCount++;
            } else if (c.getVisibility() == View.VISIBLE
                    && (c instanceof ViewGroup
                            || c instanceof ImageView
                            || c instanceof EditText)) {
                return false;
            }
        }
        return btnCount >= 1;
    }

    private static void stylePluginHorizontalButtonBar(MainActivity a, LinearLayout row) {
        boolean firstPass = STYLED_BUTTON_ROWS.add(row);
        if (firstPass) {
            row.setBackgroundColor(Color.TRANSPARENT);
            row.setMinimumWidth(0);
            row.setWeightSum(-1f);
            row.setPadding(0, a.dp(6), 0, a.dp(2));
            ViewGroup.LayoutParams rawLp = row.getLayoutParams();
            if (rawLp != null) {
                rawLp.width = ViewGroup.LayoutParams.MATCH_PARENT;
                if (rawLp instanceof ViewGroup.MarginLayoutParams) {
                    applyHorizontalMargins((ViewGroup.MarginLayoutParams) rawLp, 0, 0, 0, 0);
                }
                row.setLayoutParams(rawLp);
            }
        }

        List<Button> buttons = new ArrayList<>();
        for (int i = 0; i < row.getChildCount(); i++) {
            View c = row.getChildAt(i);
            if (c instanceof Button && c.getVisibility() != View.GONE) {
                buttons.add((Button) c);
            } else if (firstPass && !(c instanceof Button)) {
                // Collapse fixed-width spacers that push trailing buttons off screen
                ViewGroup.LayoutParams slp = c.getLayoutParams();
                if (slp instanceof LinearLayout.LayoutParams) {
                    LinearLayout.LayoutParams lslp = (LinearLayout.LayoutParams) slp;
                    lslp.width = 0;
                    lslp.weight = 0f;
                    applyHorizontalMargins(lslp, 0, 0, 0, 0);
                    c.setLayoutParams(lslp);
                    c.setVisibility(View.GONE);
                }
            }
        }

        if (buttons.size() == 1) {
            Button only = buttons.get(0);
            if (firstPass) {
                row.setGravity(Gravity.END | Gravity.CENTER_VERTICAL);
                only.setMinWidth(0);
                only.setMinimumWidth(0);
                only.setMinHeight(a.dp(36));
                only.setMinimumHeight(a.dp(36));
                if (only.getLayoutParams() instanceof LinearLayout.LayoutParams) {
                    LinearLayout.LayoutParams blp =
                            (LinearLayout.LayoutParams) only.getLayoutParams();
                    blp.width = ViewGroup.LayoutParams.WRAP_CONTENT;
                    blp.height = a.dp(36);
                    blp.weight = 0f;
                    applyHorizontalMargins(blp, 0, 0, 0, 0);
                    only.setLayoutParams(blp);
                }
                only.setPadding(a.dp(18), 0, a.dp(18), 0);
            }
            applyIosActionCapsuleStyle(a, only, false);
        } else if (buttons.size() > 1) {
            if (firstPass) {
                row.setGravity(Gravity.CENTER_VERTICAL);
                row.setWeightSum((float) buttons.size());
            }
            int gap = a.dp(a.isTvDevice() ? 10 : 8);
            int btnH = a.dp(a.isTvDevice() ? 40 : 38);
            for (int i = 0; i < buttons.size(); i++) {
                Button b = buttons.get(i);
                if (firstPass) {
                    b.setMinWidth(0);
                    b.setMinimumWidth(0);
                    b.setMinHeight(btnH);
                    b.setMinimumHeight(btnH);
                    if (b.getLayoutParams() instanceof LinearLayout.LayoutParams) {
                        LinearLayout.LayoutParams blp =
                                (LinearLayout.LayoutParams) b.getLayoutParams();
                        blp.width = 0;
                        blp.height = btnH;
                        blp.weight = 1f;
                        applyHorizontalMargins(blp, 0, 0, i < buttons.size() - 1 ? gap : 0, 0);
                        b.setLayoutParams(blp);
                    }
                    b.setPadding(a.dp(10), 0, a.dp(10), 0);
                }
                applyIosActionCapsuleStyle(a, b, i == 0 && !isCancelLabel(textOf(b)));
            }
        }
    }

    private static boolean isCancelLabel(String text) {
        return text.contains("取消") || text.contains("关闭") || text.contains("返回");
    }

    private static void styleSpiderDriveRow(MainActivity a, LinearLayout row) {
        TextView accountBtn = null;
        TextView statusBtn = null;
        for (int i = 0; i < row.getChildCount(); i++) {
            View child = row.getChildAt(i);
            if (!(child instanceof TextView)) continue;
            String label = textOf((TextView) child);
            if (isDriveStatusToggleLabel(label)) {
                if (statusBtn == null) statusBtn = (TextView) child;
            } else if (detectDriveKeyFromLabel(label) != null || accountBtn == null) {
                accountBtn = (TextView) child;
            }
        }
        if (accountBtn == null) return;
        String accountLabel = textOf(accountBtn);
        String statusLabel = statusBtn == null ? "" : textOf(statusBtn);
        AccountPanel.recordObservedSpiderRow(a, accountLabel, statusLabel);

        boolean loggedIn =
                accountLabel.contains("已登录")
                        || accountLabel.contains("已绑定")
                        || accountLabel.contains("已配置");
        boolean enabled = statusLabel.contains("启用中") || statusLabel.contains("已启用");

        boolean firstPass = STYLED_DRIVE_ROWS.add(row);
        String rowStateKey = "row:" + accountLabel + "|" + statusLabel;
        Drawable existingRowBg = row.getBackground();
        if (!(existingRowBg instanceof StyledSpiderButtonBg)
                || !rowStateKey.equals(((StyledSpiderButtonBg) existingRowBg).appliedKey)) {
            // Match iOS _buildDriveTile obsidian-slate gradient (#2E2E36 -> #1E1E24)
            StyledSpiderButtonBg rowCard =
                    new StyledSpiderButtonBg(
                            rowStateKey,
                            GradientDrawable.Orientation.TOP_BOTTOM,
                            new int[] {0xc42e2e36, 0xc41e1e24});
            rowCard.setCornerRadius(a.dp(16));
            rowCard.setStroke(
                    Math.max(1, a.dp(0.8f)),
                    (loggedIn && enabled) ? 0x7a30d158 : (loggedIn ? 0x4830d158 : 0x24ffffff));
            row.setBackground(rowCard);
        }

        if (firstPass) {
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setMinimumWidth(0);
            row.setWeightSum(-1f);
            boolean tv = a.isTvDevice();
            row.setPadding(a.dp(12), a.dp(8), a.dp(10), a.dp(8));

            ViewGroup.LayoutParams rawLp = row.getLayoutParams();
            if (rawLp != null) {
                rawLp.width = ViewGroup.LayoutParams.MATCH_PARENT;
                if (rawLp instanceof ViewGroup.MarginLayoutParams) {
                    applyHorizontalMargins((ViewGroup.MarginLayoutParams) rawLp, 0, 0, 0, a.dp(9));
                }
                row.setLayoutParams(rawLp);
            }

            accountBtn.setMinWidth(0);
            accountBtn.setMinimumWidth(0);
            accountBtn.setMinHeight(0);
            accountBtn.setMinimumHeight(0);
            if (accountBtn.getLayoutParams() instanceof LinearLayout.LayoutParams) {
                LinearLayout.LayoutParams leftLp =
                        (LinearLayout.LayoutParams) accountBtn.getLayoutParams();
                leftLp.width = 0;
                leftLp.weight = 1f;
                leftLp.height = a.dp(tv ? 42 : 38);
                applyHorizontalMargins(leftLp, 0, 0, statusBtn != null ? a.dp(10) : 0, 0);
                accountBtn.setLayoutParams(leftLp);
            }
            accountBtn.setPadding(a.dp(12), 0, a.dp(10), 0);

            if (statusBtn != null) {
                statusBtn.setMinWidth(0);
                statusBtn.setMinimumWidth(0);
                statusBtn.setMinHeight(0);
                statusBtn.setMinimumHeight(0);
                if (statusBtn.getLayoutParams() instanceof LinearLayout.LayoutParams) {
                    LinearLayout.LayoutParams rightLp =
                            (LinearLayout.LayoutParams) statusBtn.getLayoutParams();
                    rightLp.width = a.dp(tv ? 86 : 72);
                    rightLp.weight = 0f;
                    rightLp.height = a.dp(tv ? 36 : 32);
                    applyHorizontalMargins(rightLp, 0, 0, 0, 0);
                    statusBtn.setLayoutParams(rightLp);
                }
                statusBtn.setPadding(a.dp(8), 0, a.dp(8), 0);
            }
        }

        if (accountBtn instanceof Button) applySpiderDriveAccountButton(a, (Button) accountBtn);
        if (statusBtn instanceof Button) applySpiderDriveStatusPill(a, (Button) statusBtn);
    }

    private static void refreshSpiderButtonStates(MainActivity a, ViewGroup root) {
        if (root == null) return;
        for (int i = 0; i < root.getChildCount(); i++) {
            View child = root.getChildAt(i);
            if (child instanceof LinearLayout && isSpiderDriveRow((LinearLayout) child)) {
                styleSpiderDriveRow(a, (LinearLayout) child);
            } else if (child instanceof LinearLayout && STYLED_BUTTON_ROWS.contains(child)) {
                stylePluginHorizontalButtonBar(a, (LinearLayout) child);
            } else if (child instanceof ListView) {
                ListView lv = (ListView) child;
                for (int j = 0; j < lv.getChildCount(); j++) {
                    styleListItem(a, lv.getChildAt(j));
                }
            } else if (child instanceof Button) {
                Button btn = (Button) child;
                int id = btn.getId();
                if (id != android.R.id.button1
                        && id != android.R.id.button2
                        && id != android.R.id.button3) {
                    applyIosActionCapsuleStyle(a, btn, false);
                }
            } else if (child instanceof ViewGroup) {
                refreshSpiderButtonStates(a, (ViewGroup) child);
            }
        }
    }

    private static final class StyledSpiderButtonBg extends GradientDrawable {
        final String appliedKey;

        StyledSpiderButtonBg(String appliedKey) {
            this.appliedKey = appliedKey;
        }

        StyledSpiderButtonBg(String appliedKey, Orientation orientation, int[] colors) {
            super(orientation, colors);
            this.appliedKey = appliedKey;
        }
    }

    private static final class StyledSpiderStateBg extends StateListDrawable {
        final String appliedKey;

        StyledSpiderStateBg(String appliedKey, Drawable normal, Drawable focused) {
            this.appliedKey = appliedKey;
            addState(new int[] {android.R.attr.state_focused}, focused);
            addState(new int[] {android.R.attr.state_pressed}, focused);
            addState(new int[] {}, normal);
        }
    }

    private static Drawable buildStatefulPill(
            MainActivity a,
            String stateKey,
            int radiusPx,
            int normalFill,
            int normalStroke,
            float normalStrokeDp,
            int focusFill,
            int focusStroke) {
        GradientDrawable normal = new GradientDrawable();
        normal.setShape(GradientDrawable.RECTANGLE);
        normal.setCornerRadius(radiusPx);
        normal.setColor(normalFill);
        if (normalStroke != 0) normal.setStroke(Math.max(1, a.dp(normalStrokeDp)), normalStroke);

        GradientDrawable focused = new GradientDrawable();
        focused.setShape(GradientDrawable.RECTANGLE);
        focused.setCornerRadius(radiusPx);
        focused.setColor(focusFill);
        focused.setStroke(Math.max(2, a.dp(2f)), focusStroke);

        return new StyledSpiderStateBg(stateKey, normal, focused);
    }

    private static boolean hasAppliedKey(Drawable existing, String stateKey) {
        if (existing instanceof StyledSpiderStateBg) {
            return stateKey.equals(((StyledSpiderStateBg) existing).appliedKey);
        }
        return existing instanceof StyledSpiderButtonBg
                && stateKey.equals(((StyledSpiderButtonBg) existing).appliedKey);
    }

    private static void applySpiderDriveAccountButton(MainActivity a, Button btn) {
        String label = textOf(btn);
        String stateKey = "acct:" + label;
        if (hasAppliedKey(btn.getBackground(), stateKey)) {
            return;
        }
        boolean loggedIn = label.contains("已登录") || label.contains("已绑定") || label.contains("已配置");

        Drawable bg =
                buildStatefulPill(
                        a,
                        stateKey,
                        a.dp(11),
                        loggedIn ? 0x1c30d158 : 0x10ffffff,
                        loggedIn ? 0x4230d158 : 0x16ffffff,
                        0.6f,
                        loggedIn ? 0x4230d158 : 0x36ffffff,
                        0xffffffff);

        btn.setAllCaps(false);
        btn.setIncludeFontPadding(false);
        btn.setSingleLine(true);
        btn.setEllipsize(TextUtils.TruncateAt.END);
        btn.setGravity(Gravity.START | Gravity.CENTER_VERTICAL);
        btn.setTypeface(null, Typeface.BOLD);
        btn.setTextSize(13.5f);
        btn.setTextColor(loggedIn ? 0xffffffff : 0xe6f5f5f7);
        UiCompat.setDefaultFocusHighlightEnabled(btn, false);
        if (Build.VERSION.SDK_INT >= 21) {
            btn.setStateListAnimator(null);
            btn.setElevation(0f);
        }
        btn.setBackground(bg);
    }

    private static void applySpiderDriveStatusPill(MainActivity a, Button btn) {
        String label = textOf(btn);
        String stateKey = "pill:" + label;
        if (hasAppliedKey(btn.getBackground(), stateKey)) {
            return;
        }
        boolean enabled = label.contains("启用中") || label.contains("已启用");

        Drawable bg =
                buildStatefulPill(
                        a,
                        stateKey,
                        a.dp(999),
                        enabled ? 0x3330d158 : 0xa63a3a42,
                        enabled ? 0x7330d158 : 0x24ffffff,
                        0.6f,
                        enabled ? 0x6630d158 : 0xd04f5564,
                        0xffffffff);

        btn.setAllCaps(false);
        btn.setIncludeFontPadding(false);
        btn.setSingleLine(true);
        btn.setEllipsize(TextUtils.TruncateAt.END);
        btn.setGravity(Gravity.CENTER);
        btn.setTypeface(null, Typeface.BOLD);
        btn.setTextSize(a.isTvDevice() ? 12.5f : 11.8f);
        btn.setTextColor(enabled ? 0xff4ade80 : 0xd9f5f5f7);
        UiCompat.setDefaultFocusHighlightEnabled(btn, false);
        if (Build.VERSION.SDK_INT >= 21) {
            btn.setStateListAnimator(null);
            btn.setElevation(0f);
        }
        btn.setBackground(bg);
    }

    private static void applyIosActionCapsuleStyle(
            MainActivity a, Button btn, boolean highlightPrimary) {
        String label = textOf(btn);
        String stateKey = (highlightPrimary ? "pri:" : "sec:") + label;
        if (hasAppliedKey(btn.getBackground(), stateKey)) {
            return;
        }

        boolean positive = label.contains("已登录") || label.contains("启用中") || label.contains("已启用");
        boolean cancel = isCancelLabel(label);

        int fill;
        int stroke;
        int focusFill;
        int textCol;
        if (highlightPrimary && !cancel) {
            fill = 0xfff5f5f7;
            stroke = 0x00000000;
            focusFill = 0xffffffff;
            textCol = 0xff111114;
        } else if (positive) {
            fill = 0x3330d158;
            stroke = 0x7330d158;
            focusFill = 0x6630d158;
            textCol = 0xff4ade80;
        } else if (cancel) {
            fill = 0x8c3a3a42;
            stroke = 0x26ffffff;
            focusFill = 0xcc505664;
            textCol = 0xe6f5f5f7;
        } else {
            fill = 0x280a84ff;
            stroke = 0x660a84ff;
            focusFill = 0x5c0a84ff;
            textCol = 0xff82c4ff;
        }

        Drawable bg =
                buildStatefulPill(
                        a,
                        stateKey,
                        a.dp(999),
                        fill,
                        stroke,
                        0.8f,
                        focusFill,
                        highlightPrimary && !cancel ? 0xff0a84ff : 0xffffffff);

        btn.setAllCaps(false);
        btn.setIncludeFontPadding(false);
        btn.setSingleLine(true);
        btn.setEllipsize(TextUtils.TruncateAt.END);
        btn.setGravity(Gravity.CENTER);
        btn.setTypeface(null, Typeface.BOLD);
        btn.setTextSize(13f);
        btn.setTextColor(textCol);
        UiCompat.setDefaultFocusHighlightEnabled(btn, false);
        if (Build.VERSION.SDK_INT >= 21) {
            btn.setStateListAnimator(null);
            btn.setElevation(0f);
        }
        btn.setBackground(bg);
    }

    private static void styleGenericPluginButton(
            MainActivity a, Button btn, boolean inHScroll, boolean inHorizontalRow) {
        int id = btn.getId();
        if (id == android.R.id.button1
                || id == android.R.id.button2
                || id == android.R.id.button3) {
            return;
        }
        btn.setMinWidth(0);
        btn.setMinimumWidth(0);
        btn.setMinHeight(a.dp(38));
        btn.setMinimumHeight(a.dp(38));
        if (shouldExpandToMatchParent(inHScroll, inHorizontalRow)) {
            ViewGroup.LayoutParams lp = btn.getLayoutParams();
            if (lp != null && lp.width > 0) {
                lp.width = ViewGroup.LayoutParams.MATCH_PARENT;
                btn.setLayoutParams(lp);
            }
        }
        btn.setPadding(a.dp(12), a.dp(6), a.dp(12), a.dp(6));
        applyIosActionCapsuleStyle(a, btn, false);
    }

    private static void styleAlertButtonBar(MainActivity a, ViewGroup cardRoot) {
        int[] ids = {android.R.id.button3, android.R.id.button2, android.R.id.button1};
        List<Button> visibleBtns = new ArrayList<>();
        ViewGroup bar = null;
        for (int id : ids) {
            View found = cardRoot.findViewById(id);
            if (!(found instanceof Button) || found.getVisibility() != View.VISIBLE) continue;
            Button b = (Button) found;
            visibleBtns.add(b);
            if (bar == null && b.getParent() instanceof ViewGroup) {
                bar = (ViewGroup) b.getParent();
            }
        }
        if (visibleBtns.isEmpty()) return;
        if (bar != null) {
            bar.setPadding(0, a.dp(8), 0, 0);
            bar.setBackgroundColor(Color.TRANSPARENT);
            bar.setMinimumWidth(0);
            ViewGroup.LayoutParams plp = bar.getLayoutParams();
            if (plp != null && plp.width != ViewGroup.LayoutParams.MATCH_PARENT) {
                plp.width = ViewGroup.LayoutParams.MATCH_PARENT;
                bar.setLayoutParams(plp);
            }
            if (bar instanceof LinearLayout) {
                ((LinearLayout) bar).setWeightSum(-1f);
            }
            boolean multi = visibleBtns.size() >= 2;
            for (int i = 0; i < bar.getChildCount(); i++) {
                View sibling = bar.getChildAt(i);
                if (!(sibling instanceof Button)
                        && sibling.getLayoutParams() instanceof LinearLayout.LayoutParams) {
                    LinearLayout.LayoutParams slp =
                            (LinearLayout.LayoutParams) sibling.getLayoutParams();
                    slp.width = 0;
                    slp.weight = multi ? 0f : 1f;
                    sibling.setLayoutParams(slp);
                    if (multi) sibling.setVisibility(View.GONE);
                }
            }
        }
        boolean multi = visibleBtns.size() >= 2;
        int gap = a.dp(8);
        for (int i = 0; i < visibleBtns.size(); i++) {
            Button b = visibleBtns.get(i);
            int id = b.getId();
            boolean primary = (id == android.R.id.button1);
            Drawable pill =
                    buildStatefulPill(
                            a,
                            "alert:" + id,
                            a.dp(999),
                            primary ? 0xff0a84ff : 0x8c3a3a42,
                            primary ? 0 : 0x26ffffff,
                            0.8f,
                            primary ? 0xff309cff : 0xcc505664,
                            0xffffffff);
            b.setAllCaps(false);
            b.setIncludeFontPadding(false);
            b.setSingleLine(true);
            b.setEllipsize(TextUtils.TruncateAt.END);
            b.setTypeface(null, Typeface.BOLD);
            b.setTextSize(13f);
            b.setTextColor(primary ? Color.WHITE : 0xe6f5f5f7);
            b.setMinHeight(a.dp(38));
            b.setMinimumHeight(a.dp(38));
            b.setMinWidth(0);
            b.setMinimumWidth(0);
            b.setPadding(a.dp(multi ? 10 : 18), a.dp(6), a.dp(multi ? 10 : 18), a.dp(6));
            UiCompat.setDefaultFocusHighlightEnabled(b, false);
            if (Build.VERSION.SDK_INT >= 21) {
                b.setStateListAnimator(null);
                b.setElevation(0f);
            }
            b.setBackground(pill);
            ViewGroup.LayoutParams lp = b.getLayoutParams();
            if (lp instanceof LinearLayout.LayoutParams) {
                LinearLayout.LayoutParams blp = (LinearLayout.LayoutParams) lp;
                if (multi) {
                    blp.width = 0;
                    blp.weight = 1f;
                    applyHorizontalMargins(blp, i == 0 ? 0 : gap, a.dp(2), 0, 0);
                } else {
                    applyHorizontalMargins(blp, a.dp(8), a.dp(2), 0, 0);
                }
                b.setLayoutParams(blp);
            } else if (lp instanceof ViewGroup.MarginLayoutParams) {
                applyHorizontalMargins((ViewGroup.MarginLayoutParams) lp, a.dp(8), a.dp(2), 0, 0);
                b.setLayoutParams(lp);
            }
        }
    }

    private static void stylePluginTextView(
            MainActivity a,
            TextView tv,
            String resName,
            boolean inHScroll,
            boolean inHorizontalRow) {
        if (shouldExpandToMatchParent(inHScroll, inHorizontalRow)) {
            ViewGroup.LayoutParams lp = tv.getLayoutParams();
            if (lp != null && lp.width > 0) {
                lp.width = ViewGroup.LayoutParams.MATCH_PARENT;
                tv.setLayoutParams(lp);
            }
        }
        boolean isAlertTitle = "alertTitle".equals(resName) || tv.getId() == android.R.id.title;
        if (isAlertTitle) {
            tv.setTextSize(15f);
            tv.setTypeface(null, Typeface.BOLD);
            tv.setTextColor(0xfff5f5f7);
            tv.setSingleLine(false);
            tv.setMaxLines(2);
            tv.setEllipsize(TextUtils.TruncateAt.END);
            tv.setLineSpacing(a.dp(2), 1f);
            tv.setPadding(a.dp(2), a.dp(2), a.dp(2), a.dp(10));
            return;
        }
        int curColor = tv.getCurrentTextColor();
        if (Color.alpha(curColor) > 80
                && Color.red(curColor) < 95
                && Color.green(curColor) < 95
                && Color.blue(curColor) < 95) {
            tv.setTextColor(0xe6f5f5f7);
        } else if (tv.getId() == android.R.id.message) {
            tv.setTextColor(0xd9ebebf5);
            tv.setTextSize(13.5f);
            tv.setLineSpacing(a.dp(3), 1f);
        }
    }

    private static void styleEditText(
            MainActivity a, EditText input, boolean inHScroll, boolean inHorizontalRow) {
        if (shouldExpandToMatchParent(inHScroll, inHorizontalRow)) {
            ViewGroup.LayoutParams lp = input.getLayoutParams();
            if (lp != null && lp.width > 0) {
                lp.width = ViewGroup.LayoutParams.MATCH_PARENT;
                input.setLayoutParams(lp);
            }
        }
        GradientDrawable gd = new GradientDrawable();
        gd.setShape(GradientDrawable.RECTANGLE);
        gd.setCornerRadius(a.dp(14));
        gd.setColor(0x992c2c34);
        gd.setStroke(Math.max(1, a.dp(0.8f)), 0x36ffffff);
        input.setBackground(gd);
        input.setTextColor(Color.WHITE);
        input.setHintTextColor(0x73ebebf5);
        input.setTextSize(14f);
        input.setPadding(a.dp(14), a.dp(11), a.dp(14), a.dp(11));
        if (a.isTvDevice() && !inHScroll && !inHorizontalRow) {
            TvQrInputHelper.attachToExistingPluginEditText(a, input);
        }
    }

    private static void styleQrOrIconImageView(
            MainActivity a, ImageView iv, String resName, int winH) {
        if ("icon".equals(resName) || iv.getId() == android.R.id.icon) {
            if (iv.getDrawable() == null) iv.setVisibility(View.GONE);
            return;
        }
        ViewGroup.LayoutParams lp = iv.getLayoutParams();
        int w = lp != null && lp.width > 0 ? lp.width : iv.getMeasuredWidth();
        int h = lp != null && lp.height > 0 ? lp.height : iv.getMeasuredHeight();
        boolean likelyQr =
                (w >= a.dp(105) && h >= a.dp(105))
                        || (iv.getDrawable() != null
                                && iv.getDrawable().getIntrinsicWidth() >= 130
                                && Math.abs(
                                                iv.getDrawable().getIntrinsicWidth()
                                                        - iv.getDrawable().getIntrinsicHeight())
                                        <= 36);
        if (likelyQr) {
            boolean tv = a.isTvDevice();
            int maxQr = resolveMaxQrSizePx(winH, a.dp(tv ? 132 : 148), a.dp(tv ? 168 : 196), tv);
            if (lp != null) {
                lp.width = maxQr;
                lp.height = maxQr;
                if (lp instanceof LinearLayout.LayoutParams) {
                    ((LinearLayout.LayoutParams) lp).gravity = Gravity.CENTER_HORIZONTAL;
                    ((LinearLayout.LayoutParams) lp).topMargin = a.dp(tv ? 6 : 10);
                    ((LinearLayout.LayoutParams) lp).bottomMargin = a.dp(tv ? 6 : 10);
                } else if (lp instanceof FrameLayout.LayoutParams) {
                    ((FrameLayout.LayoutParams) lp).gravity = Gravity.CENTER_HORIZONTAL;
                }
                iv.setLayoutParams(lp);
            }
            GradientDrawable qrPad = new GradientDrawable();
            qrPad.setShape(GradientDrawable.RECTANGLE);
            qrPad.setCornerRadius(a.dp(16));
            qrPad.setColor(Color.WHITE);
            iv.setBackground(qrPad);
            iv.setPadding(a.dp(8), a.dp(8), a.dp(8), a.dp(8));
            iv.setScaleType(ImageView.ScaleType.FIT_CENTER);
        }
    }

    private static void styleListView(final MainActivity a, ListView lv) {
        if (STYLED_LIST_VIEWS.add(lv)) {
            lv.setBackgroundColor(Color.TRANSPARENT);
            lv.setCacheColorHint(Color.TRANSPARENT);
            lv.setDivider(new ColorDrawable(0x18ffffff));
            lv.setDividerHeight(1);
            lv.setSelector(new ColorDrawable(0x1cffffff));
        }
        for (int i = 0; i < lv.getChildCount(); i++) {
            styleListItem(a, lv.getChildAt(i));
        }
    }

    private static void styleListItem(MainActivity a, View child) {
        if (child instanceof TextView) {
            if (!STYLED_LIST_ITEMS.add(child)) return;
            TextView tv = (TextView) child;
            tv.setTextColor(0xfff5f5f7);
            tv.setTextSize(14.5f);
            tv.setMinHeight(a.dp(46));
            tv.setGravity(Gravity.CENTER_VERTICAL);
            tv.setPadding(a.dp(14), a.dp(10), a.dp(14), a.dp(10));
            if (tv instanceof CheckedTextView && Build.VERSION.SDK_INT >= 21) {
                tv.setCompoundDrawableTintList(
                        android.content.res.ColorStateList.valueOf(0xff0a84ff));
            }
        } else if (child instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) child;
            for (int i = 0; i < vg.getChildCount(); i++) {
                styleListItem(a, vg.getChildAt(i));
            }
        }
    }

    private static String textOf(TextView tv) {
        return tv == null || tv.getText() == null ? "" : tv.getText().toString().trim();
    }

    private static String resourceEntryName(View v) {
        int id = v.getId();
        if (id == View.NO_ID) return "";
        try {
            return v.getResources().getResourceEntryName(id);
        } catch (Throwable ignored) {
            return "";
        }
    }
}
