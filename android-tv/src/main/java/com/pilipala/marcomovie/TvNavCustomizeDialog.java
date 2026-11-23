// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.app.Dialog;
import android.graphics.Bitmap;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.InputFilter;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.List;

/**
 * TV Navigation Bar customizer dialog: supports D-pad reordering, per-module renaming, live top-bar
 * preview, AND live phone QR drag-and-drop editing via {@link NavCustomizeServer}.
 */
final class TvNavCustomizeDialog {
    private TvNavCustomizeDialog() {}

    static void show(MainActivity a, Runnable onDone) {
        if (a == null || a.isFinishing()) return;
        final List<TvNavConfig.Module>[] state = new List[] {TvNavConfig.load(a)};
        final int[] grabbed = new int[] {-1};

        LinearLayout root = a.vertical();
        root.setTag("tv-nav-customize-root");

        // 1. Live preview strip of the TV top navigation bar
        TextView previewLabel = a.text("实时顶部导航预览", 11.5f, MainActivity.MUTED);
        previewLabel.setPadding(0, 0, 0, a.dp(4));
        root.addView(previewLabel);

        LinearLayout previewStrip = a.row();
        previewStrip.setTag("tv-nav-preview-strip");
        previewStrip.setGravity(Gravity.CENTER_VERTICAL);
        previewStrip.setPadding(a.dp(8), a.dp(6), a.dp(8), a.dp(6));
        GradientDrawable previewBg = new GradientDrawable();
        previewBg.setColor(0x28ffffff);
        previewBg.setCornerRadius(a.dp(14));
        previewBg.setStroke(Math.max(1, a.dp(1)), 0x26ffffff);
        previewStrip.setBackground(previewBg);
        root.addView(previewStrip, new LinearLayout.LayoutParams(-1, -2));

        a.gap(root, 10);

        // 2. Two-column body: Left = TV D-pad reorder + rename list; Right = Phone QR live drag
        // card
        LinearLayout columns = a.row();
        columns.setGravity(Gravity.TOP);

        LinearLayout listCol = a.vertical();
        TextView hintTv = a.text("遥控器：左右键移动顺序 · 确认键抓取拖动 · 右侧「改名」修改名称", 11.5f, 0xffa8b4c7);
        hintTv.setPadding(0, 0, 0, a.dp(6));
        listCol.addView(hintTv);

        LinearLayout rowsHost = a.vertical();
        rowsHost.setTag("tv-nav-rows");
        listCol.addView(rowsHost, new LinearLayout.LayoutParams(-1, -2));

        LinearLayout.LayoutParams leftLp = new LinearLayout.LayoutParams(0, -2, 1.38f);
        leftLp.rightMargin = a.dp(14);
        columns.addView(listCol, leftLp);

        // Right column: live Phone QR card
        LinearLayout qrCol = a.vertical();
        qrCol.setTag("tv-nav-qr-card");
        qrCol.setGravity(Gravity.CENTER_HORIZONTAL);
        qrCol.setPadding(a.dp(12), a.dp(12), a.dp(12), a.dp(12));
        GradientDrawable qrCardBg = new GradientDrawable();
        qrCardBg.setColor(0x1effffff);
        qrCardBg.setCornerRadius(a.dp(16));
        qrCardBg.setStroke(Math.max(1, a.dp(1)), 0x2cffffff);
        qrCol.setBackground(qrCardBg);

        TextView qrTitle = a.text("手机扫码拖动编辑", 13.5f, MainActivity.WHITE);
        qrTitle.setTypeface(null, Typeface.BOLD);
        qrCol.addView(qrTitle);

        TextView qrSub = a.text("同 Wi-Fi 下扫码即可拖动排序并修改名称", 11f, MainActivity.MUTED);
        qrSub.setGravity(Gravity.CENTER);
        qrSub.setPadding(0, a.dp(4), 0, a.dp(8));
        qrCol.addView(qrSub);

        ImageView qrImg = new ImageView(a);
        qrImg.setScaleType(ImageView.ScaleType.FIT_CENTER);
        int qrPx = a.dp(146);
        GradientDrawable qrFrame = new GradientDrawable();
        qrFrame.setColor(0xffffffff);
        qrFrame.setCornerRadius(a.dp(10));
        qrImg.setBackground(qrFrame);
        qrImg.setPadding(a.dp(6), a.dp(6), a.dp(6), a.dp(6));
        qrCol.addView(qrImg, new LinearLayout.LayoutParams(qrPx, qrPx));

        TextView qrUrlTv = a.text("", 10.5f, 0xff93c5fd);
        qrUrlTv.setGravity(Gravity.CENTER);
        qrUrlTv.setSingleLine(true);
        qrUrlTv.setEllipsize(TextUtils.TruncateAt.MIDDLE);
        qrUrlTv.setPadding(0, a.dp(8), 0, a.dp(4));
        qrCol.addView(qrUrlTv, new LinearLayout.LayoutParams(-1, -2));

        TextView qrStatusTv = a.text("等待手机连接…", 11f, 0xff34d399);
        qrStatusTv.setGravity(Gravity.CENTER);
        qrCol.addView(qrStatusTv);

        columns.addView(qrCol, new LinearLayout.LayoutParams(0, -2, 0.82f));
        root.addView(columns, new LinearLayout.LayoutParams(-1, -2));

        final Runnable[] renderAllRef = new Runnable[1];
        final int[] pendingFocusRow = new int[] {-1};

        renderAllRef[0] =
                () -> {
                    List<TvNavConfig.Module> mods = state[0];
                    // Refresh preview strip
                    previewStrip.removeAllViews();
                    for (int i = 0; i < mods.size(); i++) {
                        TvNavConfig.Module m = mods.get(i);
                        TextView chip =
                                a.text(m.label, 11.5f, i == 0 ? 0xff0d121a : MainActivity.WHITE);
                        chip.setSingleLine(true);
                        chip.setTypeface(null, Typeface.BOLD);
                        chip.setPadding(a.dp(8), a.dp(4), a.dp(8), a.dp(4));
                        GradientDrawable cb = new GradientDrawable();
                        cb.setColor(i == 0 ? 0xfff5f7fb : 0x24ffffff);
                        cb.setCornerRadius(a.dp(99));
                        chip.setBackground(cb);
                        LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(-2, -2);
                        if (i > 0) clp.leftMargin = a.dp(5);
                        previewStrip.addView(chip, clp);
                    }

                    // Refresh editable list
                    rowsHost.removeAllViews();
                    List<View> moveFocusViews = new ArrayList<>(mods.size());
                    for (int i = 0; i < mods.size(); i++) {
                        final int idx = i;
                        final TvNavConfig.Module m = mods.get(i);
                        boolean isGrabbed = grabbed[0] == idx;

                        LinearLayout row = a.row();
                        row.setGravity(Gravity.CENTER_VERTICAL);
                        LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(-1, -2);
                        if (i > 0) rlp.topMargin = a.dp(5);

                        Button moveBtn = new Button(a);
                        moveBtn.setAllCaps(false);
                        moveBtn.setId(View.generateViewId());
                        moveBtn.setTag("nav-custom-row:" + m.key);
                        String title =
                                (idx + 1)
                                        + ". "
                                        + m.label
                                        + (m.isCustomizedName()
                                                ? "（默认:" + m.defaultLabel + "）"
                                                : "")
                                        + (isGrabbed ? "  [上下移动中]" : "");
                        moveBtn.setText(title);
                        moveBtn.setTextSize(13f);
                        moveBtn.setSingleLine(true);
                        moveBtn.setEllipsize(TextUtils.TruncateAt.END);
                        moveBtn.setGravity(Gravity.START | Gravity.CENTER_VERTICAL);
                        moveBtn.setPadding(a.dp(12), a.dp(7), a.dp(10), a.dp(7));
                        moveBtn.setMinHeight(a.dp(38));
                        moveBtn.setMinimumHeight(a.dp(38));
                        moveBtn.setFocusable(true);
                        moveBtn.setFocusableInTouchMode(true);
                        styleRowBtn(a, moveBtn, false, isGrabbed);
                        moveBtn.setOnFocusChangeListener(
                                (v, focused) ->
                                        styleRowBtn(a, moveBtn, focused, grabbed[0] == idx));
                        moveBtn.setOnClickListener(
                                v -> {
                                    grabbed[0] = (grabbed[0] == idx) ? -1 : idx;
                                    pendingFocusRow[0] = idx;
                                    renderAllRef[0].run();
                                });
                        moveBtn.setOnKeyListener(
                                (v, keyCode, event) -> {
                                    if (event.getAction() != KeyEvent.ACTION_DOWN) return false;
                                    if (keyCode == KeyEvent.KEYCODE_DPAD_LEFT && idx > 0) {
                                        state[0] = TvNavConfig.move(state[0], idx, idx - 1);
                                        TvNavConfig.save(a, state[0]);
                                        grabbed[0] = grabbed[0] == idx ? idx - 1 : -1;
                                        pendingFocusRow[0] = idx - 1;
                                        renderAllRef[0].run();
                                        return true;
                                    }
                                    if (keyCode == KeyEvent.KEYCODE_DPAD_RIGHT
                                            && grabbed[0] == idx
                                            && idx < state[0].size() - 1) {
                                        state[0] = TvNavConfig.move(state[0], idx, idx + 1);
                                        TvNavConfig.save(a, state[0]);
                                        grabbed[0] = idx + 1;
                                        pendingFocusRow[0] = idx + 1;
                                        renderAllRef[0].run();
                                        return true;
                                    }
                                    if (grabbed[0] == idx) {
                                        if (keyCode == KeyEvent.KEYCODE_DPAD_UP && idx > 0) {
                                            state[0] = TvNavConfig.move(state[0], idx, idx - 1);
                                            TvNavConfig.save(a, state[0]);
                                            grabbed[0] = idx - 1;
                                            pendingFocusRow[0] = idx - 1;
                                            renderAllRef[0].run();
                                            return true;
                                        }
                                        if (keyCode == KeyEvent.KEYCODE_DPAD_DOWN
                                                && idx < state[0].size() - 1) {
                                            state[0] = TvNavConfig.move(state[0], idx, idx + 1);
                                            TvNavConfig.save(a, state[0]);
                                            grabbed[0] = idx + 1;
                                            pendingFocusRow[0] = idx + 1;
                                            renderAllRef[0].run();
                                            return true;
                                        }
                                        if (keyCode == KeyEvent.KEYCODE_BACK) {
                                            grabbed[0] = -1;
                                            pendingFocusRow[0] = idx;
                                            renderAllRef[0].run();
                                            return true;
                                        }
                                    }
                                    return false;
                                });
                        LinearLayout.LayoutParams mbLp = new LinearLayout.LayoutParams(0, -2, 1f);
                        mbLp.rightMargin = a.dp(6);
                        row.addView(moveBtn, mbLp);
                        moveFocusViews.add(moveBtn);

                        Button renameBtn = new Button(a);
                        renameBtn.setAllCaps(false);
                        renameBtn.setId(View.generateViewId());
                        renameBtn.setText("改名");
                        renameBtn.setTextSize(12f);
                        renameBtn.setPadding(a.dp(10), a.dp(7), a.dp(10), a.dp(7));
                        renameBtn.setMinHeight(a.dp(38));
                        renameBtn.setMinimumHeight(a.dp(38));
                        renameBtn.setMinWidth(a.dp(54));
                        renameBtn.setMinimumWidth(a.dp(54));
                        renameBtn.setFocusable(true);
                        renameBtn.setFocusableInTouchMode(true);
                        styleRowBtn(a, renameBtn, false, false);
                        renameBtn.setOnFocusChangeListener(
                                (v, focused) -> styleRowBtn(a, renameBtn, focused, false));
                        renameBtn.setOnClickListener(
                                v ->
                                        showRenameDialog(
                                                a,
                                                m,
                                                newName -> {
                                                    state[0] =
                                                            TvNavConfig.rename(
                                                                    state[0], m.key, newName);
                                                    TvNavConfig.save(a, state[0]);
                                                    pendingFocusRow[0] = idx;
                                                    renderAllRef[0].run();
                                                }));
                        row.addView(renameBtn, new LinearLayout.LayoutParams(-2, -2));

                        moveBtn.setNextFocusRightId(renameBtn.getId());
                        renameBtn.setNextFocusLeftId(moveBtn.getId());
                        rowsHost.addView(row, rlp);
                    }

                    if (pendingFocusRow[0] >= 0 && pendingFocusRow[0] < moveFocusViews.size()) {
                        final View target = moveFocusViews.get(pendingFocusRow[0]);
                        pendingFocusRow[0] = -1;
                        target.post(target::requestFocus);
                    }
                };

        // Start LAN QR Server
        final NavCustomizeServer[] serverRef = new NavCustomizeServer[1];
        try {
            String ip = PhoneConfigDialog.lanAddress();
            if (ip != null && !ip.isEmpty()) {
                serverRef[0] =
                        new NavCustomizeServer(
                                ip,
                                new NavCustomizeServer.Listener() {
                                    @Override
                                    public List<TvNavConfig.Module> currentModules() {
                                        return state[0];
                                    }

                                    @Override
                                    public void onModulesSaved(List<TvNavConfig.Module> updated) {
                                        a.ui.post(
                                                () -> {
                                                    if (a.isFinishing()) return;
                                                    state[0] = updated;
                                                    TvNavConfig.save(a, updated);
                                                    qrStatusTv.setText("已同步手机修改 ✓");
                                                    renderAllRef[0].run();
                                                });
                                    }

                                    @Override
                                    public void onModulesReset(List<TvNavConfig.Module> defaults) {
                                        a.ui.post(
                                                () -> {
                                                    if (a.isFinishing()) return;
                                                    state[0] = defaults;
                                                    TvNavConfig.reset(a);
                                                    qrStatusTv.setText("已同步恢复默认 ✓");
                                                    renderAllRef[0].run();
                                                });
                                    }
                                });
                String url = serverRef[0].url();
                Bitmap qr = TvQrInputHelper.renderQrBitmap(url, qrPx);
                if (qr != null) qrImg.setImageBitmap(qr);
                qrUrlTv.setText(url);
            } else {
                qrImg.setVisibility(View.GONE);
                qrUrlTv.setText("未检测到局域网连接");
                qrStatusTv.setText("请连接 Wi-Fi 或网线后使用手机扫码");
                qrStatusTv.setTextColor(MainActivity.MUTED);
            }
        } catch (Exception err) {
            qrImg.setVisibility(View.GONE);
            qrUrlTv.setText("手机服务暂不可用");
            qrStatusTv.setText("仍可直接使用遥控器调整");
            qrStatusTv.setTextColor(MainActivity.MUTED);
        }

        renderAllRef[0].run();

        Dialog dlg =
                new AppDialog.Builder(a)
                        .setTitle("自定义导航栏顺序与名称")
                        .setView(root)
                        .setNeutralButton(
                                "恢复默认",
                                (d, w) -> {
                                    TvNavConfig.reset(a);
                                    a.toast("已恢复默认导航栏");
                                })
                        .setPositiveButton("完成", null)
                        .create();
        dlg.setOnDismissListener(
                d -> {
                    if (serverRef[0] != null) {
                        serverRef[0].close();
                        serverRef[0] = null;
                    }
                    if (onDone != null) onDone.run();
                });
        dlg.show();
    }

    private static void showRenameDialog(
            MainActivity a, TvNavConfig.Module module, MainActivity.Done<String> onConfirm) {
        LinearLayout box = a.vertical();
        EditText input = new EditText(a);
        input.setText(module.label);
        input.setHint("默认：" + module.defaultLabel + "（最多 " + TvNavConfig.MAX_LABEL_LEN + " 字）");
        input.setTextColor(MainActivity.WHITE);
        input.setHintTextColor(0x88cbd5e1);
        input.setSingleLine(true);
        input.setFilters(
                new InputFilter[] {new InputFilter.LengthFilter(TvNavConfig.MAX_LABEL_LEN)});
        input.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(0x28ffffff);
        bg.setCornerRadius(a.dp(12));
        bg.setStroke(Math.max(1, a.dp(1)), 0x44ffffff);
        input.setBackground(bg);
        View wrapped = TvQrInputHelper.wrap(a, input, "修改「" + module.defaultLabel + "」显示名称");
        box.addView(wrapped, new LinearLayout.LayoutParams(-1, -2));

        new AppDialog.Builder(a)
                .setTitle("修改「" + module.defaultLabel + "」名称")
                .setMessage("留空将自动恢复为默认名称「" + module.defaultLabel + "」。")
                .setView(box)
                .setNegativeButton("取消", null)
                .setPositiveButton(
                        "保存",
                        (d, w) -> {
                            String val = input.getText() != null ? input.getText().toString() : "";
                            if (onConfirm != null) {
                                try {
                                    onConfirm.accept(val);
                                } catch (Exception ignored) {
                                }
                            }
                        })
                .show();
    }

    private static void styleRowBtn(MainActivity a, Button btn, boolean focused, boolean grabbed) {
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(a.dp(11));
        if (focused) {
            bg.setColor(grabbed ? 0xff34d399 : 0xfff3f6fc);
            bg.setStroke(Math.max(1, a.dp(1.2f)), 0xffffffff);
            btn.setTextColor(0xff0f141e);
        } else if (grabbed) {
            bg.setColor(0x4034d399);
            bg.setStroke(Math.max(1, a.dp(1.2f)), 0xaa34d399);
            btn.setTextColor(0xffa7f3d0);
        } else {
            bg.setColor(0x1effffff);
            bg.setStroke(Math.max(1, a.dp(1)), 0x26ffffff);
            btn.setTextColor(MainActivity.WHITE);
        }
        btn.setBackground(bg);
    }
}
