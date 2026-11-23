package com.pilipala.marcomovie;

import android.graphics.Color;
import android.graphics.Typeface;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/**
 * TV & Mobile settings panel for the local LAN Spider Gateway ({@code marco-spider-gateway-v1}),
 * letting iOS / macOS / Windows Marco Movie devices auto-discover and pair with this Android device
 * over UDP 41978 + HTTP Bearer authentication.
 */
final class SpiderGatewayDialog {
    private SpiderGatewayDialog() {}

    static String statusSummary(MainActivity a) {
        if (a == null || a.prefs == null) return "默认关闭（按需开启）";
        boolean enabled = a.prefs.getBoolean(Prefs.SPIDER_GATEWAY_ENABLED, false);
        if (!enabled) return "已关闭 · 开启后可供 iOS / macOS / Windows 局域网发现";
        SpiderGatewayServer gw = a.spiderGateway;
        if (gw != null && !gw.closed) {
            String ip = safeLanIp();
            String addr = ip.isEmpty() ? "端口 " + gw.httpPort : gw.baseUrl(ip);
            return "运行中 · " + addr + "（UDP " + gw.discoveryPort + "）";
        }
        return "已启用 · 正在启动局域网监听…";
    }

    static void show(MainActivity a) {
        show(a, null);
    }

    static void show(MainActivity a, Runnable onUpdated) {
        if (a == null || a.isFinishing()) return;
        if (a.privateMode) {
            a.toast("隐私模式下不开放局域网蜘蛛网关服务");
            return;
        }
        boolean enabled = a.prefs.getBoolean(Prefs.SPIDER_GATEWAY_ENABLED, false);
        String token = SpiderGatewayServer.ensureToken(a);
        String deviceName = SpiderGatewayServer.defaultDeviceName(a);
        SpiderGatewayServer gw = a.spiderGateway;
        boolean running = enabled && gw != null && !gw.closed;
        String lanIp = safeLanIp();

        ScrollView scroll = new TvScrollView(a);
        LinearLayout panel = a.vertical();
        panel.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(4));
        scroll.addView(panel);

        TextView intro =
                a.text(
                        "开启后，同一 Wi-Fi 下的 iPhone / iPad / Mac / Windows 端 Marco Movie 可在「设置 → 蜘蛛扩展与网关 → 局域网发现 Android 端」自动搜到本机，用本机原生解析 .so 线路（只传目录与播放地址，视频流仍由对方直连）。",
                        13,
                        MainActivity.MUTED);
        intro.setLineSpacing(a.dp(3), 1f);
        panel.addView(intro);
        a.gap(panel, 10);

        // Status & pairing card
        LinearLayout card = a.vertical();
        card.setPadding(a.dp(14), a.dp(12), a.dp(14), a.dp(12));
        card.setBackground(TvV17Surface.rounded(0x66161b26, a.dp(14), 0x2cffffff, a.dp(1)));

        String badgeText =
                running
                        ? ("● 服务运行中"
                                + (gw.isUdpDiscoveryActive()
                                        ? " · UDP 41978 自动发现已就绪"
                                        : " · HTTP 已就绪"))
                        : (enabled ? "● 正在启动局域网服务…" : "○ 服务已关闭（默认关闭）");
        TextView badge = a.text(badgeText, 13.5f, running ? 0xff4ade80 : 0xff94a3b8);
        badge.setTypeface(null, Typeface.BOLD);
        card.addView(badge);
        a.gap(card, 8);

        LinearLayout infoRow = a.row();
        infoRow.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout details = a.vertical();

        addMetaRow(a, details, "设备名称", deviceName, MainActivity.WHITE);
        String addrText =
                running && !lanIp.isEmpty()
                        ? gw.baseUrl(lanIp)
                        : (enabled
                                ? (lanIp.isEmpty()
                                        ? "未检测到局域网 IP"
                                        : "http://"
                                                + lanIp
                                                + ":"
                                                + a.prefs.getInt(
                                                        Prefs.SPIDER_GATEWAY_PORT,
                                                        SpiderGatewayServer.DEFAULT_HTTP_PORT))
                                : "开启后自动显示局域网地址");
        addMetaRow(a, details, "网关地址", addrText, 0xff66d4cf);
        addMetaRow(a, details, "访问令牌", SpiderGatewayServer.formatDisplayToken(token), 0xfffbbf24);
        if (running) {
            TextView activity =
                    a.text(
                            gw.lastActivity + "（累计 " + gw.servedRequests.get() + " 次）",
                            11.5f,
                            MainActivity.MUTED);
            activity.setPadding(0, a.dp(6), 0, 0);
            details.addView(activity);
        }
        infoRow.addView(details, new LinearLayout.LayoutParams(0, -2, 1f));

        if (running && !lanIp.isEmpty()) {
            try {
                int qrPx = a.dp(a.isTvDevice() ? 104 : 112);
                LinearLayout qrBox = a.vertical();
                qrBox.setGravity(Gravity.CENTER_HORIZONTAL);
                LinearLayout.LayoutParams qrBoxLp = new LinearLayout.LayoutParams(-2, -2);
                qrBoxLp.leftMargin = a.dp(12);
                ImageView qrImg = new ImageView(a);
                qrImg.setImageBitmap(TvQrInputHelper.renderQrBitmap(gw.pairUrl(lanIp), qrPx));
                qrImg.setPadding(a.dp(6), a.dp(6), a.dp(6), a.dp(6));
                qrImg.setBackground(a.bg(Color.WHITE, 10));
                qrBox.addView(
                        qrImg, new LinearLayout.LayoutParams(qrPx + a.dp(12), qrPx + a.dp(12)));
                TextView qrCap = a.text("手机扫码复制令牌", 10.5f, MainActivity.MUTED);
                qrCap.setPadding(0, a.dp(4), 0, 0);
                qrBox.addView(qrCap);
                infoRow.addView(qrBox, qrBoxLp);
            } catch (Throwable ignored) {
            }
        }
        card.addView(infoRow, new LinearLayout.LayoutParams(-1, -2));
        panel.addView(card, new LinearLayout.LayoutParams(-1, -2));
        a.gap(panel, 12);

        final AppDialog[] holder = new AppDialog[1];
        LinearLayout actions = a.row();
        actions.setClipChildren(false);
        actions.setClipToPadding(false);

        Button toggleBtn =
                a.navButton(
                        enabled ? "关闭网关" : "开启网关",
                        "spider-gateway-toggle",
                        () -> {
                            boolean next = !enabled;
                            a.prefs.edit().putBoolean(Prefs.SPIDER_GATEWAY_ENABLED, next).apply();
                            a.syncSpiderGateway();
                            if (holder[0] != null) holder[0].dismiss();
                            if (onUpdated != null) onUpdated.run();
                            else a.refresh();
                            a.toast(next ? "已开启局域网蜘蛛网关，iOS 端现在可搜到本机" : "已关闭局域网蜘蛛网关");
                            a.ui.postDelayed(() -> show(a, onUpdated), next ? 350L : 80L);
                        });
        Button resetBtn =
                a.navButton(
                        "重置令牌",
                        "spider-gateway-reset-token",
                        () -> {
                            SpiderGatewayServer.resetToken(a);
                            if (a.prefs.getBoolean(Prefs.SPIDER_GATEWAY_ENABLED, false)) {
                                a.restartSpiderGateway();
                            }
                            if (holder[0] != null) holder[0].dismiss();
                            a.toast("已生成新的访问令牌，请在新设备上重新核对");
                            a.ui.postDelayed(() -> show(a, onUpdated), 250L);
                        });
        Button renameBtn =
                a.navButton(
                        "修改名称",
                        "spider-gateway-rename",
                        () -> {
                            if (holder[0] != null) holder[0].dismiss();
                            promptRename(a, deviceName, onUpdated);
                        });

        LinearLayout.LayoutParams b1 = new LinearLayout.LayoutParams(0, -2, 1f);
        b1.rightMargin = a.dp(8);
        LinearLayout.LayoutParams b2 = new LinearLayout.LayoutParams(0, -2, 1f);
        b2.rightMargin = a.dp(8);
        LinearLayout.LayoutParams b3 = new LinearLayout.LayoutParams(0, -2, 1f);
        actions.addView(toggleBtn, b1);
        actions.addView(resetBtn, b2);
        actions.addView(renameBtn, b3);
        panel.addView(actions, new LinearLayout.LayoutParams(-1, -2));

        AppDialog dialog =
                new AppDialog.Builder(a)
                        .setTitle("局域网蜘蛛网关")
                        .setView(scroll)
                        .setNegativeButton("关闭", null)
                        .create();
        holder[0] = dialog;
        dialog.show();
        if (a.isTvDevice()) {
            a.ui.post(toggleBtn::requestFocus);
        }
    }

    private static void addMetaRow(
            MainActivity a, LinearLayout parent, String label, String value, int valueColor) {
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(0, a.dp(3), 0, a.dp(3));
        TextView k = a.text(label, 12, MainActivity.MUTED);
        row.addView(k, new LinearLayout.LayoutParams(a.dp(62), -2));
        TextView v = a.text(value, 13.5f, valueColor);
        v.setTypeface(Typeface.MONOSPACE, Typeface.BOLD);
        row.addView(v, new LinearLayout.LayoutParams(0, -2, 1f));
        parent.addView(row, new LinearLayout.LayoutParams(-1, -2));
    }

    private static void promptRename(MainActivity a, String currentName, Runnable onUpdated) {
        LinearLayout box = a.vertical();
        box.setPadding(a.dp(4), a.dp(6), a.dp(4), a.dp(4));
        final EditText edit = new EditText(a);
        edit.setSingleLine(true);
        edit.setText(currentName);
        edit.setSelection(edit.getText().length());
        edit.setHint("例如：客厅电视 · Marco Movie");
        edit.setTextColor(MainActivity.WHITE);
        edit.setHintTextColor(MainActivity.MUTED);
        edit.setBackground(a.bg(0xff242834, 12));
        edit.setPadding(a.dp(14), a.dp(10), a.dp(14), a.dp(10));
        View row = TvQrInputHelper.wrap(a, edit, "蜘蛛网关设备名称");
        box.addView(row, new LinearLayout.LayoutParams(-1, -2));
        new AppDialog.Builder(a)
                .setTitle("修改蜘蛛网关设备名称")
                .setView(box)
                .setPositiveButton(
                        "保存",
                        (d, w) -> {
                            String next =
                                    SearchInputServer.sanitizeKeyword(
                                            edit.getText() == null
                                                    ? ""
                                                    : edit.getText().toString());
                            if (next.isEmpty()) next = "Marco Movie Android 网关";
                            a.prefs.edit().putString(Prefs.SPIDER_GATEWAY_NAME, next).apply();
                            if (a.spiderGateway != null) a.spiderGateway.updateDeviceName(next);
                            a.toast("网关名称已更新为：" + next);
                            show(a, onUpdated);
                        })
                .setNegativeButton("取消", (d, w) -> show(a, onUpdated))
                .show();
    }

    private static String safeLanIp() {
        try {
            return PhoneConfigDialog.lanAddress();
        } catch (Exception ignored) {
            return "";
        }
    }
}
