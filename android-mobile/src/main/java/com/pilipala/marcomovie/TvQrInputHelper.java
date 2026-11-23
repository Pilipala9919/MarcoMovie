package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.PopupWindow;
import android.widget.TextView;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;

/**
 * TV remote input helper: adapts {@link EditText} controls for D-pad navigation, attaches a crisp
 * inline QR code icon button beside every TV text field, and extends an anchored speech-bubble QR
 * popover directly from that icon button so users can send text from their phone over LAN.
 */
final class TvQrInputHelper {
    static final String TAG_WRAPPED_INPUT = "tv-qr-wrapped-input";
    static final String TAG_QR_BUTTON = "tv-qr-input-button";
    static final String TAG_QR_BUBBLE = "tv-qr-input-bubble";

    static final int EDGE_TOP = 0;
    static final int EDGE_BOTTOM = 1;
    static final int EDGE_LEFT = 2;

    static final class BubblePlacement {
        final int x;
        final int y;
        final int pointerEdge;
        final int pointerOffsetPx;

        BubblePlacement(int x, int y, int pointerEdge, int pointerOffsetPx) {
            this.x = x;
            this.y = y;
            this.pointerEdge = pointerEdge;
            this.pointerOffsetPx = pointerOffsetPx;
        }
    }

    private static ActiveBubble activeBubble;

    private static final class ActiveBubble {
        final PopupWindow popup;
        final RemoteInputServer server;
        final View anchor;
        final View.OnAttachStateChangeListener detachListener;
        boolean dismissed;

        ActiveBubble(
                PopupWindow popup,
                RemoteInputServer server,
                View anchor,
                View.OnAttachStateChangeListener detachListener) {
            this.popup = popup;
            this.server = server;
            this.anchor = anchor;
            this.detachListener = detachListener;
        }

        void close() {
            if (dismissed) return;
            dismissed = true;
            if (activeBubble == this) activeBubble = null;
            if (anchor != null && detachListener != null) {
                try {
                    anchor.removeOnAttachStateChangeListener(detachListener);
                } catch (Throwable ignored) {
                }
            }
            if (server != null) {
                try {
                    server.close();
                } catch (Throwable ignored) {
                }
            }
            if (popup != null && popup.isShowing()) {
                try {
                    popup.dismiss();
                } catch (Throwable ignored) {
                }
            }
        }
    }

    private TvQrInputHelper() {}

    static void dismissActive() {
        ActiveBubble cur = activeBubble;
        if (cur != null) cur.close();
    }

    /**
     * Pure-JVM anchored popover placement math. Prefers extending out to the right when requested
     * and ample horizontal space exists (e.g. search left column), otherwise extends below the QR
     * button (flipping above when near the bottom edge), clamped strictly inside screen bounds.
     */
    static BubblePlacement computeBubblePlacement(
            int anchorLeft,
            int anchorTop,
            int anchorW,
            int anchorH,
            int bubbleW,
            int bubbleH,
            int screenW,
            int screenH,
            int marginPx,
            int gapPx,
            int cornerGuardPx,
            boolean preferSide) {
        int safeW = Math.max(bubbleW + marginPx * 2, screenW);
        int safeH = Math.max(bubbleH + marginPx * 2, screenH);
        int anchorCx = anchorLeft + Math.max(1, anchorW) / 2;
        int anchorCy = anchorTop + Math.max(1, anchorH) / 2;

        if (preferSide && anchorLeft + anchorW + gapPx + bubbleW + marginPx <= safeW) {
            int x = anchorLeft + anchorW + gapPx;
            int y = clamp(anchorCy - bubbleH / 3, marginPx, safeH - marginPx - bubbleH);
            int offsetY =
                    clamp(
                            anchorCy - y,
                            cornerGuardPx,
                            Math.max(cornerGuardPx, bubbleH - cornerGuardPx));
            return new BubblePlacement(x, y, EDGE_LEFT, offsetY);
        }

        boolean fitsBelow = anchorTop + anchorH + gapPx + bubbleH + marginPx <= safeH;
        boolean fitsAbove = anchorTop - gapPx - bubbleH >= marginPx;
        int edge;
        int y;
        if (fitsBelow || !fitsAbove) {
            edge = EDGE_TOP;
            y = clamp(anchorTop + anchorH + gapPx, marginPx, safeH - marginPx - bubbleH);
        } else {
            edge = EDGE_BOTTOM;
            y = clamp(anchorTop - gapPx - bubbleH, marginPx, safeH - marginPx - bubbleH);
        }
        // Right-align the bubble with the QR icon button so the text input on the left stays
        // visible
        int desiredX = (anchorLeft + anchorW) - bubbleW + Math.min(cornerGuardPx / 2, anchorW / 2);
        int x = clamp(desiredX, marginPx, safeW - marginPx - bubbleW);
        int offsetX =
                clamp(
                        anchorCx - x,
                        cornerGuardPx,
                        Math.max(cornerGuardPx, bubbleW - cornerGuardPx));
        return new BubblePlacement(x, y, edge, offsetX);
    }

    private static int clamp(int value, int min, int max) {
        if (max < min) return min;
        return Math.max(min, Math.min(max, value));
    }

    /**
     * Wraps an {@link EditText} into a TV-remote-friendly horizontal row with a focusable inline QR
     * code icon button on the right. On touch phones/tablets, returns {@code input} unchanged.
     */
    static View wrap(MainActivity a, EditText input, String fieldLabel) {
        return wrap(a, input, fieldLabel, false, false, false, null);
    }

    static View wrap(
            MainActivity a,
            EditText input,
            String fieldLabel,
            boolean multiline,
            boolean password,
            boolean numericPin,
            Runnable onSubmitted) {
        return wrapInternal(
                a,
                input,
                fieldLabel,
                multiline,
                password,
                numericPin,
                onSubmitted,
                "",
                "",
                null,
                null);
    }

    /**
     * Wraps a TV {@link EditText} with an inline QR icon button whose mobile web page supports BOTH
     * text/URL entry AND local file upload (e.g. {@code .txt}, {@code .json}, {@code .m3u}, {@code
     * .m3u8} live source playlists up to 8 MB).
     */
    static View wrapWithFileUpload(
            MainActivity a,
            EditText input,
            String fieldLabel,
            boolean multiline,
            String fileAccept,
            String fileHint,
            RemoteInputServer.FileListener fileListener,
            Runnable onFileImported) {
        return wrapInternal(
                a,
                input,
                fieldLabel,
                multiline,
                false,
                false,
                null,
                fileAccept,
                fileHint,
                fileListener,
                onFileImported);
    }

    private static View wrapInternal(
            MainActivity a,
            EditText input,
            String fieldLabel,
            boolean multiline,
            boolean password,
            boolean numericPin,
            Runnable onSubmitted,
            String fileAccept,
            String fileHint,
            RemoteInputServer.FileListener fileListener,
            Runnable onFileImported) {
        if (a == null || input == null || !a.isTvDevice()) {
            return input;
        }
        adaptEditTextForTv(a, input);
        LinearLayout row = a.row();
        row.setTag(TAG_WRAPPED_INPUT);
        row.setGravity(multiline ? Gravity.TOP : Gravity.CENTER_VERTICAL);
        row.setClipChildren(false);
        row.setClipToPadding(false);

        LinearLayout.LayoutParams inputLp =
                new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        row.addView(input, inputLp);

        int btnSize = a.dp(40);
        View qrBtn =
                buildQrIconButton(
                        a, TAG_QR_BUTTON, "扫码输入" + (fieldLabel == null ? "" : " " + fieldLabel));
        qrBtn.setOnClickListener(
                v ->
                        showFieldBubble(
                                a,
                                qrBtn,
                                input,
                                fieldLabel,
                                multiline,
                                password,
                                numericPin,
                                onSubmitted,
                                fileAccept,
                                fileHint,
                                fileListener,
                                onFileImported));
        LinearLayout.LayoutParams qrLp = new LinearLayout.LayoutParams(btnSize, btnSize);
        qrLp.leftMargin = a.dp(8);
        if (multiline) qrLp.topMargin = a.dp(2);
        row.addView(qrBtn, qrLp);
        return row;
    }

    /**
     * Attaches the TV QR icon button next to an already-attached plugin {@link EditText} inside a
     * vertical {@link LinearLayout} without breaking the plugin's own {@link EditText} reference.
     */
    static void attachToExistingPluginEditText(MainActivity a, EditText input) {
        if (a == null || input == null || !a.isTvDevice()) return;
        if (Boolean.TRUE.equals(input.getTag(android.R.id.edit))) return;
        ViewGroup parent =
                input.getParent() instanceof ViewGroup ? (ViewGroup) input.getParent() : null;
        if (!(parent instanceof LinearLayout)) return;
        LinearLayout ll = (LinearLayout) parent;
        if (ll.getOrientation() != LinearLayout.VERTICAL) return;
        if (TAG_WRAPPED_INPUT.equals(ll.getTag())) return;
        int idx = ll.indexOfChild(input);
        if (idx < 0) return;

        input.setTag(android.R.id.edit, Boolean.TRUE);
        adaptEditTextForTv(a, input);
        ViewGroup.LayoutParams oldLp = input.getLayoutParams();
        ll.removeViewAt(idx);

        CharSequence hintSeq = input.getHint();
        String rawLabel =
                hintSeq != null && hintSeq.length() > 0 ? hintSeq.toString().trim() : "输入内容";
        final String label = rawLabel.length() > 16 ? "扫码输入内容" : rawLabel;
        boolean multiline =
                (input.getInputType() & android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE) != 0;
        int variation = input.getInputType() & android.text.InputType.TYPE_MASK_VARIATION;
        boolean password =
                variation == android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD
                        || variation == android.text.InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
                        || variation == android.text.InputType.TYPE_NUMBER_VARIATION_PASSWORD;

        LinearLayout row = a.row();
        row.setTag(TAG_WRAPPED_INPUT);
        row.setGravity(multiline ? Gravity.TOP : Gravity.CENTER_VERTICAL);
        row.setClipChildren(false);
        row.setClipToPadding(false);
        row.addView(
                input, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        View qrBtn = buildQrIconButton(a, TAG_QR_BUTTON, "扫码输入");
        qrBtn.setOnClickListener(
                v -> showFieldBubble(a, qrBtn, input, label, multiline, password, false, null));
        LinearLayout.LayoutParams qrLp = new LinearLayout.LayoutParams(a.dp(40), a.dp(40));
        qrLp.leftMargin = a.dp(8);
        row.addView(qrBtn, qrLp);

        LinearLayout.LayoutParams wrapLp =
                new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        if (oldLp instanceof ViewGroup.MarginLayoutParams) {
            ViewGroup.MarginLayoutParams m = (ViewGroup.MarginLayoutParams) oldLp;
            wrapLp.setMargins(m.leftMargin, m.topMargin, m.rightMargin, m.bottomMargin);
        }
        ll.addView(row, idx, wrapLp);
    }

    static void adaptEditTextForTv(MainActivity a, EditText input) {
        if (a == null || input == null || !a.isTvDevice()) return;
        UiCompat.setDefaultFocusHighlightEnabled(input, false);
        UiCompat.setShowSoftInputOnFocus(input, false);
        input.setLongClickable(false);
        input.setTextIsSelectable(false);
        input.setOnClickListener(
                v -> {
                    UiCompat.setShowSoftInputOnFocus(input, true);
                    input.requestFocus();
                    try {
                        InputMethodManager imm =
                                (InputMethodManager)
                                        a.getSystemService(Context.INPUT_METHOD_SERVICE);
                        if (imm != null) {
                            imm.showSoftInput(input, InputMethodManager.SHOW_IMPLICIT);
                        }
                    } catch (Throwable ignored) {
                    }
                });
        final View.OnFocusChangeListener prevFocus = input.getOnFocusChangeListener();
        input.setOnFocusChangeListener(
                (v, focused) -> {
                    if (!focused) {
                        UiCompat.setShowSoftInputOnFocus(input, false);
                    }
                    if (prevFocus != null) {
                        prevFocus.onFocusChange(v, focused);
                    } else {
                        FocusMotion.style(
                                a,
                                input,
                                focused,
                                0xff242834,
                                0xff323848,
                                12,
                                MainActivity.WHITE,
                                MainActivity.WHITE,
                                true,
                                1.005f);
                    }
                });
    }

    /** Crisp vector 3-finder QR icon button matching GlobalSearchScreen's Apple tvOS design. */
    static View buildQrIconButton(MainActivity a, String tag, String contentDescription) {
        final View iconBtn =
                new View(a) {
                    private final Paint strokePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
                    private final Paint fillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
                    private final RectF box = new RectF();

                    @Override
                    protected void onDraw(Canvas canvas) {
                        super.onDraw(canvas);
                        int w = getWidth();
                        int h = getHeight();
                        if (w <= 0 || h <= 0) return;
                        int tint = hasFocus() ? 0xff0b0e14 : 0xf2f5f5f7;
                        float s = Math.min(w, h) * 0.56f;
                        float ox = (w - s) * 0.5f;
                        float oy = (h - s) * 0.5f;
                        float unit = s / 7f;
                        float sw = Math.max(1.5f, unit * 0.62f);
                        float cr = unit * 0.35f;

                        strokePaint.setStyle(Paint.Style.STROKE);
                        strokePaint.setStrokeWidth(sw);
                        strokePaint.setColor(tint);
                        fillPaint.setStyle(Paint.Style.FILL);
                        fillPaint.setColor(tint);

                        drawFinder(canvas, ox, oy, unit * 3f, cr);
                        drawFinder(canvas, ox + unit * 4f, oy, unit * 3f, cr);
                        drawFinder(canvas, ox, oy + unit * 4f, unit * 3f, cr);

                        drawDot(canvas, ox + unit * 4.0f, oy + unit * 4.0f, unit * 1.1f);
                        drawDot(canvas, ox + unit * 5.9f, oy + unit * 4.0f, unit * 1.1f);
                        drawDot(canvas, ox + unit * 4.95f, oy + unit * 4.95f, unit * 1.1f);
                        drawDot(canvas, ox + unit * 4.0f, oy + unit * 5.9f, unit * 1.1f);
                        drawDot(canvas, ox + unit * 5.9f, oy + unit * 5.9f, unit * 1.1f);
                    }

                    private void drawFinder(
                            Canvas canvas, float x, float y, float size, float radius) {
                        float inset = strokePaint.getStrokeWidth() * 0.5f;
                        box.set(x + inset, y + inset, x + size - inset, y + size - inset);
                        canvas.drawRoundRect(box, radius, radius, strokePaint);
                        float pip = size * 0.34f;
                        float px = x + (size - pip) * 0.5f;
                        float py = y + (size - pip) * 0.5f;
                        box.set(px, py, px + pip, py + pip);
                        canvas.drawRoundRect(box, radius * 0.5f, radius * 0.5f, fillPaint);
                    }

                    private void drawDot(Canvas canvas, float x, float y, float size) {
                        box.set(x, y, x + size, y + size);
                        canvas.drawRoundRect(box, size * 0.25f, size * 0.25f, fillPaint);
                    }
                };
        iconBtn.setTag(tag != null ? tag : TAG_QR_BUTTON);
        iconBtn.setContentDescription(contentDescription != null ? contentDescription : "手机扫码输入");
        iconBtn.setFocusable(true);
        iconBtn.setFocusableInTouchMode(true);
        iconBtn.setClickable(true);
        UiCompat.setDefaultFocusHighlightEnabled(iconBtn, false);
        iconBtn.setBackground(TvV17Surface.rounded(0x26ffffff, a.dp(10), 0x38ffffff, a.dp(1)));
        a.pressFeedback(iconBtn);
        iconBtn.setOnFocusChangeListener(
                (v, focused) -> {
                    FocusMotion.unclipAncestors(iconBtn);
                    iconBtn.setBackground(
                            TvV17Surface.rounded(
                                    focused ? 0xffffffff : 0x26ffffff,
                                    a.dp(10),
                                    focused ? 0xffffffff : 0x38ffffff,
                                    a.dp(1)));
                    UiCompat.setElevation(iconBtn, focused ? a.dp(6) : 0);
                    iconBtn.animate()
                            .scaleX(focused ? 1.07f : 1f)
                            .scaleY(focused ? 1.07f : 1f)
                            .setDuration(a.reduced ? 0 : 120)
                            .start();
                    iconBtn.invalidate();
                });
        return iconBtn;
    }

    /** Opens an anchored QR speech-bubble popover bound to a specific {@link EditText}. */
    static void showFieldBubble(
            MainActivity a,
            View anchor,
            EditText targetInput,
            String fieldLabel,
            boolean multiline,
            boolean password,
            boolean numericPin,
            Runnable onSubmitted) {
        showFieldBubble(
                a,
                anchor,
                targetInput,
                fieldLabel,
                multiline,
                password,
                numericPin,
                onSubmitted,
                "",
                "",
                null,
                null);
    }

    static void showFieldBubble(
            MainActivity a,
            View anchor,
            EditText targetInput,
            String fieldLabel,
            boolean multiline,
            boolean password,
            boolean numericPin,
            Runnable onSubmitted,
            String fileAccept,
            String fileHint,
            RemoteInputServer.FileListener fileListener,
            Runnable onFileImported) {
        if (a == null || anchor == null || targetInput == null || a.isFinishing()) return;
        if (activeBubble != null && activeBubble.anchor == anchor && !activeBubble.dismissed) {
            dismissActive();
            return;
        }
        dismissActive();
        try {
            String ip = PhoneConfigDialog.lanAddress();
            String label =
                    fieldLabel == null || fieldLabel.trim().isEmpty()
                            ? "手机扫码输入"
                            : "扫码 · " + fieldLabel.trim();
            CharSequence hintSeq = targetInput.getHint();
            CharSequence curSeq = targetInput.getText();
            RemoteInputServer.FieldSpec spec =
                    new RemoteInputServer.FieldSpec(
                            label,
                            hintSeq == null ? "" : hintSeq.toString(),
                            curSeq == null ? "" : curSeq.toString(),
                            multiline,
                            password,
                            numericPin,
                            numericPin ? 4 : RemoteInputServer.DEFAULT_MAX_CHARS,
                            fileAccept,
                            fileHint);
            final TextView[] statusHolder = new TextView[1];
            final ActiveBubble[] bubbleRef = new ActiveBubble[1];
            RemoteInputServer.FileListener wrappedFileHandler =
                    fileListener == null
                            ? null
                            : (fileName, data) -> {
                                String resultMsg = fileListener.onFile(fileName, data);
                                a.ui.post(
                                        () -> {
                                            if (a.isFinishing()) return;
                                            if (statusHolder[0] != null) {
                                                statusHolder[0].setText(
                                                        resultMsg != null && !resultMsg.isEmpty()
                                                                ? "✓ " + resultMsg
                                                                : "✓ 文件已导入");
                                                statusHolder[0].setTextColor(0xff34d399);
                                            }
                                            a.ui.postDelayed(
                                                    () -> {
                                                        if (bubbleRef[0] != null) {
                                                            bubbleRef[0].close();
                                                        }
                                                        if (onFileImported != null) {
                                                            onFileImported.run();
                                                        }
                                                    },
                                                    450L);
                                        });
                                return resultMsg;
                            };
            RemoteInputServer server =
                    new RemoteInputServer(
                            spec,
                            (text, clear) ->
                                    a.ui.post(
                                            () -> {
                                                if (a.isFinishing()) return;
                                                String next = clear || text == null ? "" : text;
                                                targetInput.setText(next);
                                                targetInput.setSelection(next.length());
                                                if (statusHolder[0] != null) {
                                                    statusHolder[0].setText(
                                                            clear ? "✓ 已清空" : "✓ 已填入输入框");
                                                    statusHolder[0].setTextColor(0xff34d399);
                                                }
                                                a.toast(clear ? "已清空输入内容" : "已接收手机扫码输入");
                                                if (onSubmitted != null) {
                                                    onSubmitted.run();
                                                }
                                                if (!clear) {
                                                    a.ui.postDelayed(
                                                            () -> {
                                                                if (bubbleRef[0] != null) {
                                                                    bubbleRef[0].close();
                                                                }
                                                                targetInput.requestFocus();
                                                            },
                                                            350L);
                                                }
                                            }),
                            wrappedFileHandler);
            String url = server.address(ip);
            String bubbleHint =
                    fileListener != null ? "扫码输入或上传 TXT / JSON / M3U" : "手机同 Wi-Fi 扫码发送 · 返回键关闭";
            showAnchoredBubble(
                    a, anchor, label, url, bubbleHint, false, server, statusHolder, bubbleRef);
        } catch (Exception err) {
            a.toast("未检测到局域网连接，请确认电视已连网");
        }
    }

    /**
     * Opens an anchored QR speech-bubble popover for {@link GlobalSearchScreen} backed by its
     * existing {@link SearchInputServer} session (preserving search history chips & instant submit).
     */
    static void showSearchBubble(MainActivity a, View anchor, String url) {
        if (a == null || anchor == null || url == null || url.isEmpty() || a.isFinishing()) return;
        if (activeBubble != null && activeBubble.anchor == anchor && !activeBubble.dismissed) {
            dismissActive();
            return;
        }
        dismissActive();
        try {
            showAnchoredBubble(
                    a,
                    anchor,
                    "手机扫码输入搜索词",
                    url,
                    "同 Wi-Fi 扫码输入中文/拼音 · 返回关闭",
                    true,
                    null,
                    new TextView[1],
                    new ActiveBubble[1]);
        } catch (Exception err) {
            a.toast("无法生成扫码气泡，请稍后重试");
        }
    }

    private static void showAnchoredBubble(
            MainActivity a,
            View anchor,
            String title,
            String url,
            String hintText,
            boolean preferSide,
            RemoteInputServer ownedServer,
            TextView[] statusHolder,
            ActiveBubble[] bubbleRef)
            throws Exception {
        int qrPx = a.dp(146);
        int qrBoxPx = qrPx + a.dp(14);
        int bubbleContentW = a.dp(214);
        int arrowDepth = a.dp(9);
        int padH = a.dp(14);
        int padV = a.dp(12);
        int estBubbleH = a.dp(248) + arrowDepth;
        int estBubbleW = bubbleContentW + (preferSide ? arrowDepth : 0);

        int[] loc = new int[2];
        anchor.getLocationOnScreen(loc);
        int anchorW = anchor.getWidth() > 0 ? anchor.getWidth() : a.dp(40);
        int anchorH = anchor.getHeight() > 0 ? anchor.getHeight() : a.dp(40);
        int screenW = Math.max(a.windowWidth(), a.getResources().getDisplayMetrics().widthPixels);
        int screenH = Math.max(a.windowHeight(), a.getResources().getDisplayMetrics().heightPixels);
        BubblePlacement placement =
                computeBubblePlacement(
                        loc[0],
                        loc[1],
                        anchorW,
                        anchorH,
                        estBubbleW,
                        estBubbleH,
                        screenW,
                        screenH,
                        a.dp(16),
                        a.dp(4),
                        a.dp(28),
                        preferSide);

        BubbleCardView card =
                new BubbleCardView(
                        a, placement.pointerEdge, placement.pointerOffsetPx, arrowDepth, a.dp(16));
        card.setTag(TAG_QR_BUBBLE);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setGravity(Gravity.CENTER_HORIZONTAL);
        card.setPadding(
                padH + (placement.pointerEdge == EDGE_LEFT ? arrowDepth : 0),
                padV + (placement.pointerEdge == EDGE_TOP ? arrowDepth : 0),
                padH,
                padV + (placement.pointerEdge == EDGE_BOTTOM ? arrowDepth : 0));

        TextView titleView = a.text(title, 13f, MainActivity.WHITE);
        titleView.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
        titleView.setSingleLine(true);
        titleView.setEllipsize(TextUtils.TruncateAt.END);
        titleView.setGravity(Gravity.CENTER);
        titleView.setMaxWidth(bubbleContentW - padH * 2);
        card.addView(titleView, new LinearLayout.LayoutParams(-2, -2));

        ImageView qrImg = new ImageView(a);
        qrImg.setTag("tv-qr-bubble-image");
        qrImg.setContentDescription(title);
        qrImg.setImageBitmap(renderQrBitmap(url, qrPx));
        qrImg.setPadding(a.dp(7), a.dp(7), a.dp(7), a.dp(7));
        qrImg.setBackground(a.bg(Color.WHITE, 12));
        LinearLayout.LayoutParams qrLp = new LinearLayout.LayoutParams(qrBoxPx, qrBoxPx);
        qrLp.topMargin = a.dp(9);
        card.addView(qrImg, qrLp);

        TextView statusView = a.text(hintText, 11.2f, 0xffa8b8cc);
        statusView.setGravity(Gravity.CENTER);
        statusView.setSingleLine(true);
        statusView.setEllipsize(TextUtils.TruncateAt.END);
        statusView.setMaxWidth(bubbleContentW - padH * 2);
        LinearLayout.LayoutParams stLp = new LinearLayout.LayoutParams(-2, -2);
        stLp.topMargin = a.dp(8);
        card.addView(statusView, stLp);
        statusHolder[0] = statusView;

        TextView addrView = a.text(url, 10f, 0xff70b4ff);
        addrView.setGravity(Gravity.CENTER);
        addrView.setSingleLine(true);
        addrView.setEllipsize(TextUtils.TruncateAt.MIDDLE);
        addrView.setMaxWidth(bubbleContentW - padH * 2);
        LinearLayout.LayoutParams adLp = new LinearLayout.LayoutParams(-2, -2);
        adLp.topMargin = a.dp(3);
        card.addView(addrView, adLp);

        int popupW = bubbleContentW + (placement.pointerEdge == EDGE_LEFT ? arrowDepth : 0);
        card.measure(
                View.MeasureSpec.makeMeasureSpec(popupW, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED));
        int actualH = Math.max(a.dp(220), card.getMeasuredHeight());
        BubblePlacement finalPlacement =
                computeBubblePlacement(
                        loc[0],
                        loc[1],
                        anchorW,
                        anchorH,
                        popupW,
                        actualH,
                        screenW,
                        screenH,
                        a.dp(16),
                        a.dp(4),
                        a.dp(28),
                        preferSide);
        card.updatePointer(finalPlacement.pointerEdge, finalPlacement.pointerOffsetPx);
        card.setPadding(
                padH + (finalPlacement.pointerEdge == EDGE_LEFT ? arrowDepth : 0),
                padV + (finalPlacement.pointerEdge == EDGE_TOP ? arrowDepth : 0),
                padH,
                padV + (finalPlacement.pointerEdge == EDGE_BOTTOM ? arrowDepth : 0));

        final PopupWindow popup =
                new PopupWindow(card, popupW, ViewGroup.LayoutParams.WRAP_CONTENT, true);
        popup.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
        popup.setOutsideTouchable(true);
        popup.setFocusable(true);
        UiCompat.setElevation(card, a.dp(16));

        card.setFocusable(true);
        card.setFocusableInTouchMode(true);
        UiCompat.setDefaultFocusHighlightEnabled(card, false);
        card.setOnKeyListener(
                (v, keyCode, event) -> {
                    if (event.getAction() == KeyEvent.ACTION_UP
                            && (keyCode == KeyEvent.KEYCODE_BACK
                                    || keyCode == KeyEvent.KEYCODE_ESCAPE
                                    || keyCode == KeyEvent.KEYCODE_DPAD_CENTER
                                    || keyCode == KeyEvent.KEYCODE_ENTER)) {
                        dismissActive();
                        anchor.requestFocus();
                        return true;
                    }
                    return false;
                });

        View.OnAttachStateChangeListener detach =
                new View.OnAttachStateChangeListener() {
                    @Override
                    public void onViewAttachedToWindow(View v) {}

                    @Override
                    public void onViewDetachedFromWindow(View v) {
                        dismissActive();
                    }
                };
        ActiveBubble record = new ActiveBubble(popup, ownedServer, anchor, detach);
        activeBubble = record;
        bubbleRef[0] = record;
        anchor.addOnAttachStateChangeListener(detach);
        popup.setOnDismissListener(
                () -> {
                    record.close();
                    if (anchor.isAttachedToWindow()) {
                        anchor.requestFocus();
                    }
                });

        if (!a.reduced) {
            card.setAlpha(0f);
            card.setScaleX(0.92f);
            card.setScaleY(0.92f);
        }
        popup.showAtLocation(anchor, Gravity.NO_GRAVITY, finalPlacement.x, finalPlacement.y);
        card.requestFocus();
        if (!a.reduced) {
            card.animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(140L).start();
        }
    }

    static Bitmap renderQrBitmap(String content, int sizePx) throws Exception {
        int px = Math.max(96, sizePx);
        BitMatrix matrix = new QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, px, px);
        int[] pixels = new int[px * px];
        for (int y = 0; y < px; y++) {
            for (int x = 0; x < px; x++) {
                pixels[y * px + x] = matrix.get(x, y) ? Color.BLACK : Color.WHITE;
            }
        }
        return Bitmap.createBitmap(pixels, px, px, Bitmap.Config.ARGB_8888);
    }

    /** Custom speech-bubble card with integrated triangular pointer tail extending from anchor. */
    private static final class BubbleCardView extends LinearLayout {
        private int pointerEdge;
        private int pointerOffset;
        private final int arrowDepth;
        private final int cornerRadius;
        private final Paint fillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint strokePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Path bubblePath = new Path();
        private final RectF bodyRect = new RectF();

        BubbleCardView(
                Context ctx, int pointerEdge, int pointerOffset, int arrowDepth, int cornerRadius) {
            super(ctx);
            this.pointerEdge = pointerEdge;
            this.pointerOffset = pointerOffset;
            this.arrowDepth = arrowDepth;
            this.cornerRadius = cornerRadius;
            setWillNotDraw(false);
            fillPaint.setStyle(Paint.Style.FILL);
            fillPaint.setColor(0xf6151924);
            strokePaint.setStyle(Paint.Style.STROKE);
            strokePaint.setStrokeWidth(
                    Math.max(1.5f, ctx.getResources().getDisplayMetrics().density * 1.1f));
            strokePaint.setColor(0x4affffff);
        }

        void updatePointer(int edge, int offset) {
            this.pointerEdge = edge;
            this.pointerOffset = offset;
            invalidate();
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth();
            int h = getHeight();
            if (w <= 0 || h <= 0) return;
            float inset = strokePaint.getStrokeWidth() * 0.5f;
            float left = inset + (pointerEdge == EDGE_LEFT ? arrowDepth : 0);
            float top = inset + (pointerEdge == EDGE_TOP ? arrowDepth : 0);
            float right = w - inset;
            float bottom = h - inset - (pointerEdge == EDGE_BOTTOM ? arrowDepth : 0);
            float r =
                    Math.min(
                            cornerRadius, Math.min((right - left) * 0.45f, (bottom - top) * 0.45f));
            float halfArrow = arrowDepth * 0.92f;

            // Single continuous closed Path (no Path.op) so HWUI stays 100% GPU-native on API 23+.
            bubblePath.reset();
            if (pointerEdge == EDGE_TOP) {
                float cx =
                        Math.max(
                                left + r + halfArrow,
                                Math.min(right - r - halfArrow, pointerOffset));
                bubblePath.moveTo(left + r, top);
                bubblePath.lineTo(cx - halfArrow, top);
                bubblePath.lineTo(cx, inset);
                bubblePath.lineTo(cx + halfArrow, top);
                bubblePath.lineTo(right - r, top);
                bodyRect.set(right - 2 * r, top, right, top + 2 * r);
                bubblePath.arcTo(bodyRect, -90f, 90f, false);
                bubblePath.lineTo(right, bottom - r);
                bodyRect.set(right - 2 * r, bottom - 2 * r, right, bottom);
                bubblePath.arcTo(bodyRect, 0f, 90f, false);
                bubblePath.lineTo(left + r, bottom);
                bodyRect.set(left, bottom - 2 * r, left + 2 * r, bottom);
                bubblePath.arcTo(bodyRect, 90f, 90f, false);
                bubblePath.lineTo(left, top + r);
                bodyRect.set(left, top, left + 2 * r, top + 2 * r);
                bubblePath.arcTo(bodyRect, 180f, 90f, false);
                bubblePath.close();
            } else if (pointerEdge == EDGE_BOTTOM) {
                float cx =
                        Math.max(
                                left + r + halfArrow,
                                Math.min(right - r - halfArrow, pointerOffset));
                bubblePath.moveTo(left + r, top);
                bubblePath.lineTo(right - r, top);
                bodyRect.set(right - 2 * r, top, right, top + 2 * r);
                bubblePath.arcTo(bodyRect, -90f, 90f, false);
                bubblePath.lineTo(right, bottom - r);
                bodyRect.set(right - 2 * r, bottom - 2 * r, right, bottom);
                bubblePath.arcTo(bodyRect, 0f, 90f, false);
                bubblePath.lineTo(cx + halfArrow, bottom);
                bubblePath.lineTo(cx, h - inset);
                bubblePath.lineTo(cx - halfArrow, bottom);
                bubblePath.lineTo(left + r, bottom);
                bodyRect.set(left, bottom - 2 * r, left + 2 * r, bottom);
                bubblePath.arcTo(bodyRect, 90f, 90f, false);
                bubblePath.lineTo(left, top + r);
                bodyRect.set(left, top, left + 2 * r, top + 2 * r);
                bubblePath.arcTo(bodyRect, 180f, 90f, false);
                bubblePath.close();
            } else {
                float cy =
                        Math.max(
                                top + r + halfArrow,
                                Math.min(bottom - r - halfArrow, pointerOffset));
                bubblePath.moveTo(left + r, top);
                bubblePath.lineTo(right - r, top);
                bodyRect.set(right - 2 * r, top, right, top + 2 * r);
                bubblePath.arcTo(bodyRect, -90f, 90f, false);
                bubblePath.lineTo(right, bottom - r);
                bodyRect.set(right - 2 * r, bottom - 2 * r, right, bottom);
                bubblePath.arcTo(bodyRect, 0f, 90f, false);
                bubblePath.lineTo(left + r, bottom);
                bodyRect.set(left, bottom - 2 * r, left + 2 * r, bottom);
                bubblePath.arcTo(bodyRect, 90f, 90f, false);
                bubblePath.lineTo(left, cy + halfArrow);
                bubblePath.lineTo(inset, cy);
                bubblePath.lineTo(left, cy - halfArrow);
                bubblePath.lineTo(left, top + r);
                bodyRect.set(left, top, left + 2 * r, top + 2 * r);
                bubblePath.arcTo(bodyRect, 180f, 90f, false);
                bubblePath.close();
            }
            canvas.drawPath(bubblePath, fillPaint);
            canvas.drawPath(bubblePath, strokePaint);
            super.onDraw(canvas);
        }
    }
}
