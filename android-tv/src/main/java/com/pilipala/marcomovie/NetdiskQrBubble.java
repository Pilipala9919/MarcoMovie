// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.ColorFilter;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.view.animation.AccelerateInterpolator;
import android.view.animation.DecelerateInterpolator;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.PopupWindow;
import android.widget.TextView;
import java.lang.ref.WeakReference;

/**
 * Anchored floating QR-login popover bubble extending directly from the clicked netdisk button on
 * {@link AccountPanel}. Keeps the Netdisk config dialog open, captures & mirrors third-party spider
 * QR windows without layout overflow, monitors login completion via spider text / credential diff /
 * {@code RefreshEvent.config()} / auto-dismissal, and smoothly collapses back into the anchor
 * button with a "扫码成功" notification upon success.
 */
final class NetdiskQrBubble {
    static final int EDGE_LEFT = 0;
    static final int EDGE_RIGHT = 1;
    static final int EDGE_TOP = 2;
    static final int EDGE_BOTTOM = 3;

    private static final long ARM_TTL_MS = 30000L;
    private static final long MIN_AUTO_CLOSE_SUCCESS_MS = 1200L;

    static final class BubblePlacement {
        final int x;
        final int y;
        final int pointerEdge;
        final int pointerOffsetPx;
        final float pivotX;
        final float pivotY;

        BubblePlacement(
                int x, int y, int pointerEdge, int pointerOffsetPx, float pivotX, float pivotY) {
            this.x = x;
            this.y = y;
            this.pointerEdge = pointerEdge;
            this.pointerOffsetPx = pointerOffsetPx;
            this.pivotX = pivotX;
            this.pivotY = pivotY;
        }
    }

    private static final class MainHolder {
        static final Handler INSTANCE = new Handler(Looper.getMainLooper());
    }

    private static Handler mainHandler() {
        return MainHolder.INSTANCE;
    }

    private static final class ActiveSession {
        final WeakReference<MainActivity> activityRef;
        final WeakReference<View> anchorRef;
        final String driveKey;
        final String driveLabel;
        final Runnable onLoginSuccess;
        final String baselineFingerprint;
        final long armedAtMs;
        long capturedAtMs;
        PopupWindow popup;
        LinearLayout card;
        ImageView qrView;
        TextView titleView;
        TextView statusView;
        Button refreshBtn;
        Button closeBtn;
        BubblePlacement placement;
        WeakReference<ViewGroup> capturedDecorRef;
        WeakReference<ViewGroup> capturedContentRef;
        WeakReference<ImageView> sourceQrRef;
        WeakReference<Button> sourceRefreshRef;
        String lastCapturedStatus = "";
        boolean suppressDismissCallback;
        boolean userCancelled;
        boolean completed;
        boolean closing;
        Runnable pollTask;

        ActiveSession(
                MainActivity a,
                View anchor,
                String driveKey,
                String driveLabel,
                String baselineFingerprint,
                Runnable onLoginSuccess) {
            this.activityRef = new WeakReference<>(a);
            this.anchorRef = new WeakReference<>(anchor);
            this.driveKey = driveKey == null ? "" : driveKey;
            this.driveLabel =
                    driveLabel == null || driveLabel.trim().isEmpty() ? "网盘扫码" : driveLabel.trim();
            this.baselineFingerprint = baselineFingerprint == null ? "" : baselineFingerprint;
            this.onLoginSuccess = onLoginSuccess;
            this.armedAtMs = SystemClock.uptimeMillis();
        }
    }

    private static ActiveSession active;

    private NetdiskQrBubble() {}

    /**
     * Pure-JVM placement solver: chooses the cleanest side extending from the clicked button
     * (preferring Right -> Left -> Bottom -> Top) and clamps strictly inside the viewport bounds so
     * no edge or button can ever overflow.
     */
    static BubblePlacement computePlacement(
            int screenW,
            int screenH,
            int anchorLeft,
            int anchorTop,
            int anchorRight,
            int anchorBottom,
            int bubbleW,
            int bubbleH,
            int marginPx,
            int gapPx) {
        int safeW = Math.max(240, screenW);
        int safeH = Math.max(240, screenH);
        int m = Math.max(8, marginPx);
        int g = Math.max(4, gapPx);
        int bw = Math.min(Math.max(120, bubbleW), safeW - m * 2);
        int bh = Math.min(Math.max(120, bubbleH), safeH - m * 2);

        int anchorCx = (anchorLeft + anchorRight) / 2;
        int anchorCy = (anchorTop + anchorBottom) / 2;

        int spaceRight = safeW - m - (anchorRight + g);
        int spaceLeft = (anchorLeft - g) - m;
        int spaceBottom = safeH - m - (anchorBottom + g);
        int spaceTop = (anchorTop - g) - m;

        int x;
        int y;
        int edge;
        if (spaceRight >= bw) {
            edge = EDGE_LEFT;
            x = anchorRight + g;
            y = clamp(anchorCy - bh / 2, m, safeH - m - bh);
        } else if (spaceLeft >= bw) {
            edge = EDGE_RIGHT;
            x = anchorLeft - g - bw;
            y = clamp(anchorCy - bh / 2, m, safeH - m - bh);
        } else if (spaceBottom >= bh) {
            edge = EDGE_TOP;
            x = clamp(anchorCx - bw / 2, m, safeW - m - bw);
            y = anchorBottom + g;
        } else if (spaceTop >= bh) {
            edge = EDGE_BOTTOM;
            x = clamp(anchorCx - bw / 2, m, safeW - m - bw);
            y = anchorTop - g - bh;
        } else {
            // Pick the side with the largest available room and clamp cleanly inside viewport
            if (spaceRight >= spaceLeft) {
                edge = EDGE_LEFT;
                x = clamp(anchorRight + g, m, safeW - m - bw);
            } else {
                edge = EDGE_RIGHT;
                x = clamp(anchorLeft - g - bw, m, safeW - m - bw);
            }
            y = clamp(anchorCy - bh / 2, m, safeH - m - bh);
        }

        int pointerOffset;
        float pivotX;
        float pivotY;
        if (edge == EDGE_LEFT) {
            pointerOffset = clamp(anchorCy - y, Math.min(28, bh / 3), Math.max(28, bh - 28));
            pivotX = 0f;
            pivotY = pointerOffset;
        } else if (edge == EDGE_RIGHT) {
            pointerOffset = clamp(anchorCy - y, Math.min(28, bh / 3), Math.max(28, bh - 28));
            pivotX = bw;
            pivotY = pointerOffset;
        } else if (edge == EDGE_TOP) {
            pointerOffset = clamp(anchorCx - x, Math.min(28, bw / 3), Math.max(28, bw - 28));
            pivotX = pointerOffset;
            pivotY = 0f;
        } else {
            pointerOffset = clamp(anchorCx - x, Math.min(28, bw / 3), Math.max(28, bw - 28));
            pivotX = pointerOffset;
            pivotY = bh;
        }
        return new BubblePlacement(x, y, edge, pointerOffset, pivotX, pivotY);
    }

    static boolean isSuccessStatusText(String text) {
        if (text == null || text.trim().isEmpty()) return false;
        String t = text.trim();
        if (t.contains("失败")
                || t.contains("错误")
                || t.contains("过期")
                || t.contains("超时")
                || t.contains("未登录")) {
            return false;
        }
        return t.contains("登录成功")
                || t.contains("扫码成功")
                || t.contains("授权成功")
                || t.contains("绑定成功")
                || t.contains("保存成功")
                || t.contains("已登录");
    }

    static boolean isFailureStatusText(String text) {
        if (text == null || text.trim().isEmpty()) return false;
        String t = text.trim();
        return t.contains("失败")
                || t.contains("过期")
                || t.contains("超时")
                || t.contains("取消")
                || t.contains("异常");
    }

    private static int clamp(int value, int min, int max) {
        if (max < min) return min;
        return Math.max(min, Math.min(max, value));
    }

    static boolean isArmedOrShowing() {
        ActiveSession s = active;
        if (s == null || s.closing || s.completed) return false;
        if (s.popup != null && s.popup.isShowing()) return true;
        return (SystemClock.uptimeMillis() - s.armedAtMs) <= ARM_TTL_MS;
    }

    static boolean hasActiveCapturedWindow() {
        ActiveSession s = active;
        if (s == null || s.closing || s.completed) return false;
        ViewGroup decor = s.capturedDecorRef != null ? s.capturedDecorRef.get() : null;
        return decor != null && decor.isAttachedToWindow();
    }

    /**
     * Arms the QR bubble anchor for the clicked netdisk/config button. Keeps the session armed
     * without prematurely opening a focusable PopupWindow (so intermediate spider menus or loading
     * dialogs can never accidentally dismiss the session and wipe {@code active} before the real QR
     * window arrives).
     */
    static void arm(
            MainActivity a,
            View anchor,
            String driveKey,
            String driveLabel,
            Runnable onLoginSuccess) {
        if (a == null || anchor == null || !anchor.isAttachedToWindow()) return;
        dismissActive(false);
        String baseline = AccountPanel.captureCredentialFingerprint(a, driveKey);
        ActiveSession session =
                new ActiveSession(a, anchor, driveKey, driveLabel, baseline, onLoginSuccess);
        active = session;
        if (!session.driveKey.isEmpty()) {
            a.toast("正在获取 " + session.driveLabel + " 二维码…");
        }
        startPolling(session);
    }

    /**
     * Called by {@link PluginDialogStyler} when a spider opens a QR login dialog while a netdisk
     * button anchor is armed. Suppresses the overflowing raw spider dialog (while keeping its
     * background polling alive!) and mirrors the live QR image + status inside our anchored bubble.
     */
    static boolean tryCapturePluginQrWindow(MainActivity a, ViewGroup decor, ViewGroup content) {
        ActiveSession session = active;
        if (session == null || session.closing || session.completed) return false;
        if ((SystemClock.uptimeMillis() - session.armedAtMs) > ARM_TTL_MS
                && session.capturedAtMs == 0L) {
            return false;
        }
        View anchor = session.anchorRef.get();
        if (anchor == null || !anchor.isAttachedToWindow()) {
            dismissActive(false);
            return false;
        }
        ViewGroup prevDecor =
                session.capturedDecorRef != null ? session.capturedDecorRef.get() : null;
        if (prevDecor == decor && session.popup != null && session.popup.isShowing()) {
            syncCapturedWindow(a, decor);
            return true;
        }
        if (session.popup == null || !session.popup.isShowing()) {
            showBubbleWindow(a, anchor, session, "请使用手机扫码确认");
        }
        session.capturedDecorRef = new WeakReference<>(decor);
        session.capturedContentRef = new WeakReference<>(content);
        session.capturedAtMs = SystemClock.uptimeMillis();

        // Hide the raw overflowing spider window cleanly without destroying its polling thread
        suppressSpiderWindow(a, decor);

        syncCapturedWindow(a, decor);
        startPolling(session);
        return true;
    }

    /**
     * Called by {@link SourceController} when a structured JSON action returns {@code
     * type:"qrcode"} while a netdisk button is armed.
     */
    static boolean tryShowForStructuredAction(
            MainActivity a, String title, String msg, String imageUrl, String qrText) {
        ActiveSession session = active;
        if (session == null || session.closing || session.completed) return false;
        View anchor = session.anchorRef.get();
        if (anchor == null || !anchor.isAttachedToWindow()) return false;
        if (session.popup == null || !session.popup.isShowing()) {
            showBubbleWindow(a, anchor, session, msg == null || msg.isEmpty() ? "请使用手机扫码" : msg);
        }
        if (session.titleView != null && title != null && !title.isEmpty()) {
            session.titleView.setText(title);
        }
        if (session.statusView != null && msg != null && !msg.isEmpty()) {
            session.statusView.setText(msg);
        }
        if (session.qrView != null) {
            int sz = a.dp(156);
            if (qrText != null && !qrText.isEmpty()) {
                try {
                    Bitmap bmp = TvQrInputHelper.renderQrBitmap(qrText, sz);
                    if (bmp != null) session.qrView.setImageBitmap(bmp);
                } catch (Exception ignored) {
                }
            } else if (imageUrl != null && !imageUrl.isEmpty()) {
                a.poster(imageUrl, session.qrView);
            }
        }
        session.capturedAtMs = SystemClock.uptimeMillis();
        startPolling(session);
        return true;
    }

    static void syncCapturedWindow(MainActivity a, ViewGroup decor) {
        ActiveSession session = active;
        if (session == null || session.closing || session.completed) return;
        ViewGroup expected =
                session.capturedDecorRef != null ? session.capturedDecorRef.get() : null;
        if (expected != decor) return;
        suppressSpiderWindow(a, decor);

        ViewGroup content =
                session.capturedContentRef != null ? session.capturedContentRef.get() : null;
        if (content == null) return;

        // 1. Live-mirror QR ImageView
        ImageView srcImg = PluginDialogStyler.findFirstContentImageView(content, 0);
        if (srcImg != null) {
            session.sourceQrRef = new WeakReference<>(srcImg);
            Drawable d = srcImg.getDrawable();
            if (d != null && session.qrView != null) {
                Bitmap copy = extractBitmapSafe(d);
                if (copy != null) {
                    session.qrView.setImageBitmap(copy);
                } else {
                    session.qrView.setImageDrawable(
                            d.getConstantState() != null ? d.getConstantState().newDrawable() : d);
                }
            }
        }

        // 2. Live-mirror concise status text & check for explicit success message
        String status = extractBestStatusText(content, session.driveLabel);
        if (!status.isEmpty()) {
            session.lastCapturedStatus = status;
            if (session.statusView != null && !status.contentEquals(session.statusView.getText())) {
                session.statusView.setText(status);
            }
            if (isSuccessStatusText(status)) {
                completeWithSuccess(session);
                return;
            }
        }

        // 3. Mirror a refresh button if the spider offers one
        Button srcRefresh = findRefreshButton(content, 0);
        if (srcRefresh != null && session.refreshBtn != null) {
            session.sourceRefreshRef = new WeakReference<>(srcRefresh);
            if (session.refreshBtn.getVisibility() != View.VISIBLE) {
                session.refreshBtn.setVisibility(View.VISIBLE);
            }
        }
    }

    /** Called when a plugin triggers {@code RefreshEvent.config()} after login completes. */
    static void onPluginConfigRefreshed() {
        final ActiveSession session = active;
        if (session == null || session.closing || session.completed) return;
        mainHandler()
                .post(
                        () -> {
                            if (active == session && !session.closing && !session.completed) {
                                completeWithSuccess(session);
                            }
                        });
    }

    /**
     * Collapses any uncaptured placeholder popup if a non-QR spider dialog (form/menu) appears,
     * while strictly keeping the armed session alive so picking "扫码登录" inside that submenu still
     * captures into our anchored bubble!
     */
    static void hideLoadingPlaceholderIfNotCaptured() {
        ActiveSession session = active;
        if (session == null || session.closing || session.completed) return;
        if (session.capturedDecorRef == null && session.capturedAtMs == 0L) {
            if (session.popup != null && session.popup.isShowing()) {
                session.suppressDismissCallback = true;
                try {
                    session.popup.dismiss();
                } catch (Throwable ignored) {
                } finally {
                    session.suppressDismissCallback = false;
                }
            }
            session.popup = null;
        }
    }

    static void dismissActive(boolean animate) {
        final ActiveSession session = active;
        active = null;
        if (session == null) return;
        session.closing = true;
        if (session.pollTask != null) {
            mainHandler().removeCallbacks(session.pollTask);
            session.pollTask = null;
        }
        ViewGroup capturedDecor =
                session.capturedDecorRef != null ? session.capturedDecorRef.get() : null;
        ViewGroup capturedContent =
                session.capturedContentRef != null ? session.capturedContentRef.get() : null;
        if (capturedDecor != null) {
            PluginDialogStyler.releaseCapturedDecor(capturedDecor, capturedContent, true);
        }
        final PopupWindow pop = session.popup;
        final View card = session.card;
        final View anchor = session.anchorRef.get();
        if (pop == null) return;
        if (animate && card != null && pop.isShowing()) {
            if (session.placement != null) {
                card.setPivotX(session.placement.pivotX);
                card.setPivotY(session.placement.pivotY);
            }
            card.animate()
                    .scaleX(0.2f)
                    .scaleY(0.2f)
                    .alpha(0f)
                    .setDuration(200)
                    .setInterpolator(new AccelerateInterpolator())
                    .withEndAction(
                            () -> {
                                try {
                                    if (pop.isShowing()) pop.dismiss();
                                } catch (Throwable ignored) {
                                }
                                if (anchor != null && anchor.isAttachedToWindow()) {
                                    anchor.requestFocus();
                                }
                            })
                    .start();
        } else {
            try {
                if (pop.isShowing()) pop.dismiss();
            } catch (Throwable ignored) {
            }
            if (anchor != null && anchor.isAttachedToWindow()) {
                anchor.requestFocus();
            }
        }
    }

    private static void completeWithSuccess(final ActiveSession session) {
        if (session == null || session.completed || session.closing) return;
        session.completed = true;
        if (session.pollTask != null) {
            mainHandler().removeCallbacks(session.pollTask);
            session.pollTask = null;
        }
        final MainActivity a = session.activityRef.get();
        if (a != null && !a.isFinishing()) {
            if (!session.driveKey.isEmpty()) {
                AccountPanel.markDriveLoggedIn(a, session.driveKey, true);
            }
            if (session.statusView != null) {
                session.statusView.setText("✓ 扫码成功");
                session.statusView.setTextColor(0xff34d399);
            }
            if (session.onLoginSuccess != null) {
                session.onLoginSuccess.run();
            }
            a.toast(session.driveLabel + " 扫码成功");
        }
        mainHandler()
                .postDelayed(
                        () -> {
                            if (active == session) {
                                dismissActive(true);
                            } else {
                                // Still close popup if replaced
                                PopupWindow pop = session.popup;
                                if (pop != null && pop.isShowing()) {
                                    try {
                                        pop.dismiss();
                                    } catch (Throwable ignored) {
                                    }
                                }
                            }
                        },
                        320);
    }

    private static void startPolling(final ActiveSession session) {
        if (session.pollTask != null) {
            mainHandler().removeCallbacks(session.pollTask);
        }
        session.pollTask =
                new Runnable() {
                    @Override
                    public void run() {
                        if (active != session || session.closing || session.completed) return;
                        MainActivity a = session.activityRef.get();
                        View anchor = session.anchorRef.get();
                        if (a == null
                                || a.isFinishing()
                                || anchor == null
                                || !anchor.isAttachedToWindow()) {
                            dismissActive(false);
                            return;
                        }

                        // 1. Check credential fingerprint delta (works for EVERY spider!)
                        String nowFp =
                                AccountPanel.captureCredentialFingerprint(a, session.driveKey);
                        if (!nowFp.equals(session.baselineFingerprint)
                                && !nowFp.isEmpty()
                                && (session.capturedAtMs > 0L
                                        || SystemClock.uptimeMillis() - session.armedAtMs > 800L)) {
                            completeWithSuccess(session);
                            return;
                        }

                        // 2. Sync captured spider QR window OR detect spider auto-dismiss on
                        // success
                        ViewGroup decor =
                                session.capturedDecorRef != null
                                        ? session.capturedDecorRef.get()
                                        : null;
                        if (decor != null) {
                            if (!decor.isAttachedToWindow()) {
                                long elapsed = SystemClock.uptimeMillis() - session.capturedAtMs;
                                if (!session.userCancelled
                                        && !isFailureStatusText(session.lastCapturedStatus)
                                        && elapsed >= MIN_AUTO_CLOSE_SUCCESS_MS) {
                                    completeWithSuccess(session);
                                } else {
                                    dismissActive(true);
                                }
                                return;
                            }
                            syncCapturedWindow(a, decor);
                        } else if (session.capturedAtMs == 0L
                                && SystemClock.uptimeMillis() - session.armedAtMs > ARM_TTL_MS) {
                            dismissActive(false);
                            return;
                        }

                        mainHandler().postDelayed(this, 240);
                    }
                };
        mainHandler().postDelayed(session.pollTask, 200);
    }

    private static void suppressSpiderWindow(MainActivity a, ViewGroup decor) {
        if (decor == null) return;
        try {
            decor.setAlpha(0f);
            ViewGroup.LayoutParams raw = decor.getLayoutParams();
            if (raw instanceof WindowManager.LayoutParams) {
                WindowManager.LayoutParams wlp = (WindowManager.LayoutParams) raw;
                int desiredFlags =
                        (wlp.flags
                                        | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                                        | WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE)
                                & ~WindowManager.LayoutParams.FLAG_DIM_BEHIND;
                if (wlp.flags != desiredFlags
                        || wlp.width != 1
                        || wlp.height != 1
                        || wlp.x != -10000
                        || wlp.y != -10000
                        || wlp.alpha != 0f) {
                    wlp.flags = desiredFlags;
                    wlp.gravity = Gravity.TOP | Gravity.START;
                    wlp.x = -10000;
                    wlp.y = -10000;
                    wlp.width = 1;
                    wlp.height = 1;
                    wlp.alpha = 0f;
                    wlp.dimAmount = 0f;
                    WindowManager wm = (WindowManager) a.getSystemService(Context.WINDOW_SERVICE);
                    if (wm != null) wm.updateViewLayout(decor, wlp);
                }
            }
        } catch (Throwable ignored) {
        }
    }

    private static void showBubbleWindow(
            final MainActivity a,
            final View anchor,
            final ActiveSession session,
            String initialStatus) {
        final int arrowSize = a.dp(9);
        final int bubbleW = a.dp(232);
        final int qrSize = a.dp(156);
        final int bubbleH = a.dp(282);

        int[] loc = new int[2];
        anchor.getLocationInWindow(loc);
        int anchorW = Math.max(a.dp(80), anchor.getWidth());
        int anchorH = Math.max(a.dp(40), anchor.getHeight());

        final BubblePlacement place =
                computePlacement(
                        a.windowWidth(),
                        a.windowHeight(),
                        loc[0],
                        loc[1],
                        loc[0] + anchorW,
                        loc[1] + anchorH,
                        bubbleW,
                        bubbleH,
                        a.dp(14),
                        a.dp(6));
        session.placement = place;

        LinearLayout card = a.vertical();
        card.setTag("netdisk-qr-bubble");
        card.setGravity(Gravity.CENTER_HORIZONTAL);
        card.setClipChildren(true);
        card.setClipToPadding(true);
        int padL = a.dp(14) + (place.pointerEdge == EDGE_LEFT ? arrowSize : 0);
        int padT = a.dp(12) + (place.pointerEdge == EDGE_TOP ? arrowSize : 0);
        int padR = a.dp(14) + (place.pointerEdge == EDGE_RIGHT ? arrowSize : 0);
        int padB = a.dp(12) + (place.pointerEdge == EDGE_BOTTOM ? arrowSize : 0);
        card.setPadding(padL, padT, padR, padB);
        card.setBackground(
                new BubbleDrawable(
                        0xf5191d28,
                        0x46ffffff,
                        Math.max(1f, a.dp(1)),
                        a.dp(18),
                        arrowSize,
                        place.pointerEdge,
                        place.pointerOffsetPx));
        UiCompat.setElevation(card, a.dp(18));

        TextView titleTv = a.text(session.driveLabel + " · 扫码", 13.5f, MainActivity.WHITE);
        titleTv.setTypeface(null, Typeface.BOLD);
        titleTv.setSingleLine(true);
        titleTv.setEllipsize(TextUtils.TruncateAt.END);
        titleTv.setGravity(Gravity.CENTER);
        card.addView(titleTv, new LinearLayout.LayoutParams(-1, -2));

        a.gap(card, 8);

        ImageView qrIv = new ImageView(a);
        qrIv.setScaleType(ImageView.ScaleType.FIT_CENTER);
        GradientDrawable qrFrame = new GradientDrawable();
        qrFrame.setColor(0xffffffff);
        qrFrame.setCornerRadius(a.dp(12));
        qrIv.setBackground(qrFrame);
        qrIv.setPadding(a.dp(7), a.dp(7), a.dp(7), a.dp(7));
        card.addView(qrIv, new LinearLayout.LayoutParams(qrSize, qrSize));

        a.gap(card, 7);

        TextView statusTv = a.text(initialStatus, 11.5f, 0xffb8c4d9);
        statusTv.setGravity(Gravity.CENTER);
        statusTv.setMaxLines(2);
        statusTv.setEllipsize(TextUtils.TruncateAt.END);
        card.addView(statusTv, new LinearLayout.LayoutParams(-1, -2));

        a.gap(card, 8);

        LinearLayout btnRow = a.row();
        btnRow.setGravity(Gravity.CENTER);

        final Button refreshBtn =
                a.button(
                        "刷新",
                        "qr-bubble-refresh",
                        () -> {
                            Button src =
                                    session.sourceRefreshRef != null
                                            ? session.sourceRefreshRef.get()
                                            : null;
                            if (src != null && src.isAttachedToWindow()) {
                                src.performClick();
                                statusTv.setText("正在刷新二维码…");
                            }
                        });
        styleBubbleActionBtn(a, refreshBtn, false);
        refreshBtn.setVisibility(View.GONE);
        LinearLayout.LayoutParams rfLp = new LinearLayout.LayoutParams(0, a.dp(34), 1f);
        rfLp.rightMargin = a.dp(8);
        btnRow.addView(refreshBtn, rfLp);

        final Button closeBtn =
                a.button(
                        "关闭",
                        "qr-bubble-close",
                        () -> {
                            session.userCancelled = true;
                            dismissActive(true);
                        });
        styleBubbleActionBtn(a, closeBtn, true);
        btnRow.addView(closeBtn, new LinearLayout.LayoutParams(0, a.dp(34), 1f));
        card.addView(btnRow, new LinearLayout.LayoutParams(-1, -2));

        View.OnKeyListener backCancelListener =
                (v, keyCode, event) -> {
                    if (keyCode == KeyEvent.KEYCODE_BACK
                            && event.getAction() == KeyEvent.ACTION_UP) {
                        session.userCancelled = true;
                        dismissActive(true);
                        return true;
                    }
                    return false;
                };
        card.setOnKeyListener(backCancelListener);
        closeBtn.setOnKeyListener(backCancelListener);
        refreshBtn.setOnKeyListener(backCancelListener);

        FrameLayout wrapper = new FrameLayout(a);
        wrapper.setTag("netdisk-qr-bubble");
        wrapper.setOnKeyListener(backCancelListener);
        wrapper.addView(
                card, new FrameLayout.LayoutParams(bubbleW, ViewGroup.LayoutParams.WRAP_CONTENT));

        final PopupWindow pop =
                new PopupWindow(wrapper, bubbleW, ViewGroup.LayoutParams.WRAP_CONTENT, true);
        pop.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
        pop.setOutsideTouchable(!a.isTvDevice());
        pop.setTouchable(true);
        pop.setOnDismissListener(
                () -> {
                    if (!session.suppressDismissCallback && active == session && !session.closing) {
                        session.userCancelled = true;
                        dismissActive(false);
                    }
                });

        session.popup = pop;
        session.card = card;
        session.qrView = qrIv;
        session.titleView = titleTv;
        session.statusView = statusTv;
        session.refreshBtn = refreshBtn;
        session.closeBtn = closeBtn;

        card.setPivotX(place.pivotX);
        card.setPivotY(place.pivotY);
        card.setScaleX(0.22f);
        card.setScaleY(0.22f);
        card.setAlpha(0f);

        try {
            pop.showAtLocation(anchor.getRootView(), Gravity.NO_GRAVITY, place.x, place.y);
            card.animate()
                    .scaleX(1f)
                    .scaleY(1f)
                    .alpha(1f)
                    .setDuration(200)
                    .setInterpolator(new DecelerateInterpolator())
                    .start();
            closeBtn.post(closeBtn::requestFocus);
        } catch (Throwable ignored) {
            active = null;
        }
    }

    private static void styleBubbleActionBtn(MainActivity a, Button btn, boolean primary) {
        UiCompat.setDefaultFocusHighlightEnabled(btn, false);
        btn.setTextSize(12f);
        btn.setSingleLine(true);
        btn.setMinWidth(0);
        btn.setMinimumWidth(0);
        btn.setMinHeight(a.dp(34));
        btn.setMinimumHeight(a.dp(34));
        btn.setPadding(a.dp(8), 0, a.dp(8), 0);
        final int normalBg = primary ? 0x2cffffff : 0x1effffff;
        btn.setBackground(a.bg(normalBg, 999));
        btn.setTextColor(MainActivity.WHITE);
        btn.setOnFocusChangeListener(
                (v, focused) ->
                        FocusMotion.style(
                                a,
                                btn,
                                focused,
                                normalBg,
                                MainActivity.WHITE,
                                999,
                                MainActivity.WHITE,
                                MainActivity.DARK,
                                false,
                                1.03f));
    }

    private static Bitmap extractBitmapSafe(Drawable d) {
        try {
            if (d instanceof BitmapDrawable) {
                Bitmap b = ((BitmapDrawable) d).getBitmap();
                if (b != null && !b.isRecycled()) return b;
            }
            int w = d.getIntrinsicWidth();
            int h = d.getIntrinsicHeight();
            if (w <= 0 || h <= 0 || w > 1200 || h > 1200) return null;
            Bitmap out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
            Canvas c = new Canvas(out);
            d.setBounds(0, 0, w, h);
            d.draw(c);
            return out;
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static String extractBestStatusText(View root, String fallbackTitle) {
        StringBuilder best = new StringBuilder();
        collectStatusCandidate(root, best, 0);
        String s = best.toString().trim();
        if (s.isEmpty() || s.equals(fallbackTitle)) return "请使用手机扫码并在手机端确认";
        return s.length() > 42 ? s.substring(0, 41) + "…" : s;
    }

    private static void collectStatusCandidate(View v, StringBuilder out, int depth) {
        if (v == null || depth > 12) return;
        if (v instanceof TextView && !(v instanceof Button) && v.getVisibility() == View.VISIBLE) {
            CharSequence cs = ((TextView) v).getText();
            if (cs != null) {
                String t = cs.toString().replaceAll("\\s+", " ").trim();
                if (!t.isEmpty() && !t.startsWith("http")) {
                    if (isSuccessStatusText(t) || isFailureStatusText(t)) {
                        out.setLength(0);
                        out.append(t);
                        return;
                    }
                    if (out.length() == 0 && t.length() >= 3) {
                        out.append(t);
                    }
                }
            }
        }
        if (v instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) v;
            for (int i = 0; i < vg.getChildCount(); i++) {
                collectStatusCandidate(vg.getChildAt(i), out, depth + 1);
            }
        }
    }

    private static Button findRefreshButton(View v, int depth) {
        if (v == null || depth > 12) return null;
        if (v instanceof Button && v.getVisibility() == View.VISIBLE) {
            CharSequence cs = ((Button) v).getText();
            String t = cs == null ? "" : cs.toString().trim();
            if (t.contains("刷新") || t.contains("重新") || t.contains("换一")) {
                return (Button) v;
            }
        }
        if (v instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) v;
            for (int i = 0; i < vg.getChildCount(); i++) {
                Button b = findRefreshButton(vg.getChildAt(i), depth + 1);
                if (b != null) return b;
            }
        }
        return null;
    }

    private static final class BubbleDrawable extends Drawable {
        private final Paint fillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint strokePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final float radius;
        private final int arrowSize;
        private final int pointerEdge;
        private final int pointerOffset;
        private final Path path = new Path();
        private final RectF box = new RectF();

        BubbleDrawable(
                int fill,
                int stroke,
                float strokeW,
                float radius,
                int arrowSize,
                int pointerEdge,
                int pointerOffset) {
            this.radius = radius;
            this.arrowSize = arrowSize;
            this.pointerEdge = pointerEdge;
            this.pointerOffset = pointerOffset;
            fillPaint.setStyle(Paint.Style.FILL);
            fillPaint.setColor(fill);
            strokePaint.setStyle(Paint.Style.STROKE);
            strokePaint.setColor(stroke);
            strokePaint.setStrokeWidth(strokeW);
        }

        @Override
        public void draw(Canvas canvas) {
            Rect b = getBounds();
            if (b.width() <= 0 || b.height() <= 0) return;
            float inset = strokePaint.getStrokeWidth() * 0.5f;
            float l = b.left + inset + (pointerEdge == EDGE_LEFT ? arrowSize : 0);
            float t = b.top + inset + (pointerEdge == EDGE_TOP ? arrowSize : 0);
            float r = b.right - inset - (pointerEdge == EDGE_RIGHT ? arrowSize : 0);
            float bt = b.bottom - inset - (pointerEdge == EDGE_BOTTOM ? arrowSize : 0);
            box.set(l, t, r, bt);

            path.reset();
            path.addRoundRect(box, radius, radius, Path.Direction.CW);

            float halfA = arrowSize * 0.9f;
            Path tri = new Path();
            if (pointerEdge == EDGE_LEFT) {
                float cy =
                        Math.max(
                                t + radius + halfA,
                                Math.min(bt - radius - halfA, b.top + pointerOffset));
                tri.moveTo(l + 1f, cy - halfA);
                tri.lineTo(b.left + inset, cy);
                tri.lineTo(l + 1f, cy + halfA);
                tri.close();
            } else if (pointerEdge == EDGE_RIGHT) {
                float cy =
                        Math.max(
                                t + radius + halfA,
                                Math.min(bt - radius - halfA, b.top + pointerOffset));
                tri.moveTo(r - 1f, cy - halfA);
                tri.lineTo(b.right - inset, cy);
                tri.lineTo(r - 1f, cy + halfA);
                tri.close();
            } else if (pointerEdge == EDGE_TOP) {
                float cx =
                        Math.max(
                                l + radius + halfA,
                                Math.min(r - radius - halfA, b.left + pointerOffset));
                tri.moveTo(cx - halfA, t + 1f);
                tri.lineTo(cx, b.top + inset);
                tri.lineTo(cx + halfA, t + 1f);
                tri.close();
            } else {
                float cx =
                        Math.max(
                                l + radius + halfA,
                                Math.min(r - radius - halfA, b.left + pointerOffset));
                tri.moveTo(cx - halfA, bt - 1f);
                tri.lineTo(cx, b.bottom - inset);
                tri.lineTo(cx + halfA, bt - 1f);
                tri.close();
            }
            if (Build.VERSION.SDK_INT >= 19) {
                path.op(tri, Path.Op.UNION);
            } else {
                path.addPath(tri);
            }
            canvas.drawPath(path, fillPaint);
            canvas.drawPath(path, strokePaint);
        }

        @Override
        public void setAlpha(int alpha) {
            fillPaint.setAlpha(alpha);
            strokePaint.setAlpha(alpha);
        }

        @Override
        public void setColorFilter(ColorFilter colorFilter) {
            fillPaint.setColorFilter(colorFilter);
            strokePaint.setColorFilter(colorFilter);
        }

        @Override
        public int getOpacity() {
            return PixelFormat.TRANSLUCENT;
        }
    }
}
