package com.pilipala.marcomovie;

import android.view.*;
import android.widget.*;

/** Local URL keyboard; hardware keyboards and paste remain available. */
final class AddressInput extends LinearLayout {
    final MainActivity a;
    final EditText input;
    boolean upper;
    final LinearLayout keys;
    final TextView error;

    AddressInput(MainActivity host, String hint, String value) {
        this(host, hint, value, false);
    }

    AddressInput(MainActivity host, String hint, String value, boolean allowMultiline) {
        super(host);
        a = host;
        setOrientation(VERTICAL);
        setClipChildren(false);
        setClipToPadding(false);
        input = new EditText(a);
        input.setTag("address-input");
        if (allowMultiline) {
            input.setSingleLine(false);
            input.setMinLines(1);
            input.setMaxLines(4);
            input.setInputType(
                    android.text.InputType.TYPE_CLASS_TEXT
                            | android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE
                            | android.text.InputType.TYPE_TEXT_VARIATION_URI);
        } else {
            input.setSingleLine(true);
            input.setInputType(17);
        }
        input.setTextSize(16);
        input.setTextColor(MainActivity.WHITE);
        input.setHintTextColor(MainActivity.MUTED);
        input.setHint(hint);
        UiCompat.setShowSoftInputOnFocus(input, !a.isTvDevice());
        input.setPadding(a.dp(14), a.dp(10), a.dp(14), a.dp(10));
        input.setBackground(a.bg(0xff36363e, 16));
        input.setOnFocusChangeListener(
                (v, f) ->
                        FocusMotion.style(
                                a,
                                input,
                                f,
                                0xff36363e,
                                0xff41414a,
                                16,
                                MainActivity.WHITE,
                                MainActivity.WHITE,
                                true,
                                1.005f));
        input.setText(value);
        input.setSelection(input.length());
        error = a.text("", 12, 0xffffb4ad);
        String qrLabel = hint != null && hint.contains("wallpaper") ? "壁纸图片地址" : "配置地址（支持多行）";
        View inputRow =
                TvQrInputHelper.wrap(
                        a, input, qrLabel, allowMultiline, false, false, () -> error.setText(""));
        addView(
                inputRow,
                new LinearLayout.LayoutParams(
                        -1,
                        (a.isTvDevice() || allowMultiline)
                                ? ViewGroup.LayoutParams.WRAP_CONTENT
                                : a.dp(48)));
        input.setLongClickable(!a.isTvDevice());
        input.setTextIsSelectable(!a.isTvDevice());
        addView(error);
        keys = a.vertical();
        addView(keys);
        rebuild(allowMultiline);
    }

    String value() {
        return input.getText().toString().trim();
    }

    void invalid(String message) {
        error.setText(message);
        input.requestFocus();
    }

    void insert(String text) {
        int x = Math.max(0, input.getSelectionStart()), y = Math.max(0, input.getSelectionEnd());
        input.getText().replace(Math.min(x, y), Math.max(x, y), text);
        error.setText("");
    }

    void rebuild() {
        rebuild(false);
    }

    void rebuild(boolean allowMultiline) {
        keys.removeAllViews();
        if (a.isTvDevice()) {
            String chars =
                    upper
                            ? "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:/.-_?=&%#+@"
                            : "abcdefghijklmnopqrstuvwxyz0123456789:/.-_?=&%#+@";
            for (int i = 0; i < chars.length(); i += 12) {
                LinearLayout row = a.row();
                keys.addView(row);
                for (int j = i; j < Math.min(chars.length(), i + 12); j++) {
                    String c = chars.substring(j, j + 1);
                    key(row, c, () -> insert(c));
                }
            }
        }
        LinearLayout row = a.row();
        keys.addView(row);
        if (a.isTvDevice()) {
            key(
                    row,
                    "大小写",
                    () -> {
                        upper = !upper;
                        rebuild(allowMultiline);
                        keys.getChildAt(0).requestFocus();
                    });
        }
        key(row, "https://", () -> insert("https://"));
        if (allowMultiline) {
            key(row, "换行", () -> insert("\n"));
        }
        key(
                row,
                "删除",
                () -> {
                    int pos = Math.max(0, input.getSelectionStart());
                    if (pos > 0) input.getText().delete(pos - 1, pos);
                });
        key(row, "清空", () -> input.setText(""));
        if (!a.isTvDevice()) {
            key(
                    row,
                    "粘贴",
                    () -> {
                        android.content.ClipboardManager clipboard =
                                (android.content.ClipboardManager)
                                        a.getSystemService(
                                                android.content.Context.CLIPBOARD_SERVICE);
                        if (clipboard != null && clipboard.hasPrimaryClip())
                            insert(
                                    clipboard
                                            .getPrimaryClip()
                                            .getItemAt(0)
                                            .coerceToText(a)
                                            .toString());
                    });
        }
    }

    void key(LinearLayout row, String label, Runnable action) {
        Button button = a.button(label, "address-key:" + label, action);
        button.setTextSize(12);
        button.setMinWidth(0);
        button.setMinimumWidth(0);
        button.setMinHeight(0);
        button.setMinimumHeight(0);
        button.setPadding(a.dp(2), 0, a.dp(2), 0);
        button.setBackground(a.bg(0xff37373f, 12));
        button.setOnFocusChangeListener(
                (v, f) -> {
                    FocusMotion.style(
                            a,
                            button,
                            f,
                            0xff37373f,
                            MainActivity.WHITE,
                            12,
                            MainActivity.WHITE,
                            MainActivity.DARK,
                            false,
                            1.02f);
                });
        LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(0, a.dp(32), 1);
        size.setMargins(a.dp(2), a.dp(2), a.dp(2), a.dp(2));
        row.addView(button, size);
    }
}
