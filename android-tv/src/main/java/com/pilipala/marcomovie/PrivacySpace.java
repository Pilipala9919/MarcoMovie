package com.pilipala.marcomovie;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.SystemClock;
import android.text.InputType;
import android.util.Base64;
import android.widget.EditText;
import android.widget.LinearLayout;
import java.security.SecureRandom;

/** Separate private configuration namespace; unlock state exists only in this process. */
final class PrivacySpace {
    static boolean active;
    private static long lastTap;
    private static int taps;
    private static boolean dialogOpen;
    private static AppDialog pendingDialog;

    static void cancelPrompt(MainActivity owner) {
        if (pendingDialog != null && pendingDialog.a == owner) pendingDialog.dismiss();
        taps = 0;
    }

    static void logoTap(MainActivity a) {
        long now = SystemClock.elapsedRealtime();
        if (now < lastTap || now - lastTap > 2500) {
            taps = 0;
        }
        lastTap = now;
        if (++taps < 5) return;
        taps = 0;
        if (a.privateMode) {
            switchSpace(a, false);
            return;
        }
        if (dialogOpen) return;
        prompt(a);
    }

    static void openTv(MainActivity a) {
        if (!a.isTvDevice() || !a.foreground || a.switchingPrivacy || a.isFinishing() || dialogOpen)
            return;
        if (a.privateMode) switchSpace(a, false);
        else prompt(a);
    }

    private static void prompt(MainActivity a) {
        final TvSearchContext tvContext =
                a.isTvDevice() ? new TvSearchContext(a.config, a.privateMode, a.engineEpoch) : null;
        SharedPreferences lock = a.getSharedPreferences("private-lock", Context.MODE_PRIVATE);
        if (System.currentTimeMillis() < lock.getLong("retry_at", 0)) {
            a.toast("尝试次数较多，请稍后再输入密码");
            return;
        }
        boolean setup = !lock.contains("hash");
        LinearLayout panel = a.vertical();
        panel.setPadding(a.dp(12), a.dp(8), a.dp(12), a.dp(8));
        panel.addView(
                a.text(
                        setup ? "设置 4 位数字密码。私密订阅单独保存，不进入公开备份。" : "输入密码进入隐私空间",
                        15,
                        MainActivity.MUTED));
        EditText pin = input(a, "4 位数字密码");
        LinearLayout.LayoutParams pinLp = new LinearLayout.LayoutParams(-1, -2);
        pinLp.topMargin = a.dp(10);
        panel.addView(TvQrInputHelper.wrap(a, pin, "4 位隐私密码", false, true, true, null), pinLp);
        EditText confirm = input(a, "再次输入密码");
        if (setup) {
            LinearLayout.LayoutParams confirmLp = new LinearLayout.LayoutParams(-1, -2);
            confirmLp.topMargin = a.dp(10);
            panel.addView(
                    TvQrInputHelper.wrap(a, confirm, "确认 4 位隐私密码", false, true, true, null),
                    confirmLp);
        }
        if (a.isTvDevice()) {
            final EditText[] target = {pin};
            pin.setOnFocusChangeListener(
                    (v, focused) -> {
                        if (focused) target[0] = pin;
                    });
            confirm.setOnFocusChangeListener(
                    (v, focused) -> {
                        if (focused) target[0] = confirm;
                    });
            for (String digits : new String[] {"123", "456", "789", "0⌫"}) {
                LinearLayout row = a.row();
                for (int i = 0; i < digits.length(); i++) {
                    final String digit = digits.substring(i, i + 1);
                    a.addButton(
                            row,
                            a.navButton(
                                    digit,
                                    "private-pin:" + digit,
                                    () -> {
                                        if (!a.foreground
                                                || !tvContext.matches(
                                                        a.config, a.privateMode, a.engineEpoch))
                                            return;
                                        String value = target[0].getText().toString();
                                        if ("⌫".equals(digit)) {
                                            if (!value.isEmpty())
                                                target[0].setText(
                                                        value.substring(0, value.length() - 1));
                                        } else if (value.length() < 4) target[0].append(digit);
                                    }));
                }
                panel.addView(row);
            }
            if (setup)
                a.addButton(
                        panel,
                        a.navButton(
                                "填写确认密码",
                                "private-pin-confirm-field",
                                () -> {
                                    target[0] = confirm;
                                    confirm.requestFocus();
                                }));
        }
        dialogOpen = true;
        AppDialog dialog =
                new AppDialog.Builder(a)
                        .setTitle(setup ? "设置隐私密码" : "隐私空间")
                        .setView(panel)
                        .setNegativeButton("取消", null)
                        .setPositiveButton(setup ? "设置并进入" : "进入", null)
                        .create();
        pendingDialog = dialog;
        dialog.setOnDismissListener(
                d -> {
                    dialogOpen = false;
                    if (pendingDialog == dialog) pendingDialog = null;
                });
        dialog.show();
        final android.widget.Button submit = dialog.getButton(-1);
        submit.setOnClickListener(
                button -> {
                    if (!submit.isEnabled()
                            || tvContext != null
                                    && !tvContext.matches(a.config, a.privateMode, a.engineEpoch))
                        return;
                    if (System.currentTimeMillis() < lock.getLong("retry_at", 0)) {
                        a.toast("尝试次数较多，请稍后再输入密码");
                        return;
                    }
                    String value = pin.getText().toString();
                    if (!value.matches("[0-9]{4}")
                            || (setup && !value.equals(confirm.getText().toString()))) {
                        a.toast(setup ? "请输入两次相同的 4 位数字密码" : "请输入 4 位数字密码");
                        return;
                    }
                    submit.setEnabled(false);
                    a.worker.execute(
                            () -> {
                                try {
                                    final byte[] salt;
                                    final byte[] hash;
                                    final boolean accepted;
                                    if (setup) {
                                        salt = new byte[16];
                                        new SecureRandom().nextBytes(salt);
                                        hash = PrivacyPin.derive(value, salt);
                                        accepted = true;
                                    } else {
                                        salt =
                                                Base64.decode(
                                                        lock.getString("salt", ""), Base64.DEFAULT);
                                        hash =
                                                Base64.decode(
                                                        lock.getString("hash", ""), Base64.DEFAULT);
                                        accepted = PrivacyPin.matches(value, salt, hash);
                                    }
                                    a.ui.post(
                                            () -> {
                                                if (tvContext != null
                                                        && !tvContext.matches(
                                                                a.config,
                                                                a.privateMode,
                                                                a.engineEpoch)) {
                                                    dialog.dismiss();
                                                    return;
                                                }
                                                if (a.isFinishing()
                                                        || a.isDestroyed()
                                                        || !dialog.isShowing()) return;
                                                submit.setEnabled(true);
                                                if (!a.foreground) {
                                                    dialog.dismiss();
                                                    return;
                                                }
                                                if (!accepted) {
                                                    int failures = lock.getInt("failures", 0) + 1;
                                                    lock.edit()
                                                            .putInt("failures", failures)
                                                            .putLong(
                                                                    "retry_at",
                                                                    failures >= 5
                                                                            ? System
                                                                                            .currentTimeMillis()
                                                                                    + 30000
                                                                            : 0)
                                                            .apply();
                                                    pin.setText("");
                                                    a.toast("密码错误，请重新输入");
                                                } else {
                                                    SharedPreferences.Editor save =
                                                            lock.edit()
                                                                    .remove("failures")
                                                                    .remove("retry_at");
                                                    if (setup)
                                                        save.putString(
                                                                        "salt",
                                                                        Base64.encodeToString(
                                                                                salt,
                                                                                Base64.NO_WRAP))
                                                                .putString(
                                                                        "hash",
                                                                        Base64.encodeToString(
                                                                                hash,
                                                                                Base64.NO_WRAP));
                                                    save.apply();
                                                    dialog.dismiss();
                                                    switchSpace(a, true);
                                                }
                                            });
                                } catch (Exception error) {
                                    a.ui.post(
                                            () -> {
                                                if (dialog.isShowing()
                                                        && (tvContext == null
                                                                || tvContext.matches(
                                                                        a.config,
                                                                        a.privateMode,
                                                                        a.engineEpoch))) {
                                                    submit.setEnabled(true);
                                                    a.toast("隐私密码验证失败，请重试");
                                                }
                                            });
                                }
                            });
                });
    }

    private static EditText input(MainActivity a, String hint) {
        EditText input = new EditText(a);
        input.setHint(hint);
        input.setTextColor(MainActivity.WHITE);
        input.setHintTextColor(0x80ebebf5);
        input.setTextSize(15f);
        input.setInputType(InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_VARIATION_PASSWORD);
        input.setFilters(
                new android.text.InputFilter[] {new android.text.InputFilter.LengthFilter(4)});
        input.setSingleLine(true);
        input.setPadding(a.dp(14), a.dp(11), a.dp(14), a.dp(11));
        android.graphics.drawable.GradientDrawable gd =
                new android.graphics.drawable.GradientDrawable();
        gd.setCornerRadius(a.dp(14));
        gd.setColor(0x20ffffff);
        gd.setStroke(Math.max(1, a.dp(1)), 0x33ffffff);
        input.setBackground(gd);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.topMargin = a.dp(10);
        input.setLayoutParams(lp);
        return input;
    }

    static void switchSpace(MainActivity a, boolean privateMode) {
        if (a.markerHost != null) a.markerHost.abort();
        a.savePlaybackHistory(true);
        if (a.isTvDevice()) {
            a.switchingPrivacy = true;
            a.generation++; // Revoke queued page/player callbacks before recreate reaches onStop.
            CloudSyncDialog.cancel(a);
            a.stopWeb();
            a.stopCastService();
            a.stopSpiderGateway();
            if (a.phoneConfig != null) {
                PhoneConfigDialog session = a.phoneConfig;
                session.close();
                if (session.dialog != null) session.dialog.dismiss();
            }
        }
        a.cancelPageRequests();
        a.closeEngines();
        // Discard only transient derived state. Public/private persisted user data is retained.
        a.ui.removeCallbacks(a.learnPendingTitles);
        a.pendingTitles.clear();
        a.phonetic = null;
        active = privateMode;
        if (!privateMode) {
            VideoSkipStore.clearPrivateRecords();
            SubtitlePreferenceStore.clearPrivateRecords();
            VideoMarkerRepository.clearPrivate();
        }
        a.switchingPrivacy = true;
        MobileShell.activeTab = 0;
        MobileShell.clearSearchSession();
        a.recreate();
    }
}
