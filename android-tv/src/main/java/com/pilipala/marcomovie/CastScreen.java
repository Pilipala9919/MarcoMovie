package com.pilipala.marcomovie;

import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;
import java.util.Collections;

/**
 * 10-foot TV Wireless Cast Receiver Hub reachable from the Home Dock ("nav-cast").
 *
 * <p>Presents this TV exclusively as a cast receiver (matching iQIYI / Youku / Tencent / Bilibili
 * DLNA discovery &amp; phone selection) alongside a token-scoped QR direct-cast web fallback.
 */
final class CastScreen {
    final MainActivity a;
    TextView liveStatusView;
    TextView receiverBadgeView;
    TextView receiverIpView;
    LinearLayout qrHostView;
    int screenTicket;

    CastScreen(MainActivity activity) {
        a = activity;
    }

    void show() {
        a.renderPage("无线投屏", "WIRELESS CAST RECEIVER");
        a.body.setTag("cast-screen");
        screenTicket = a.generation;
        if (a.privateMode) {
            a.paragraph("当前处于隐私空间，所有局域网广播与远程投屏接收已严格隔离关闭。退出隐私空间后即可使用无线投屏。");
            Button backBtn = a.button("返回", "primary", a::onBackPressed);
            a.addButton(a.body, backBtn);
            return;
        }

        boolean enabled = a.prefs.getBoolean(Prefs.CAST_ENABLED, true);
        a.syncCastService();
        String deviceName = a.prefs.getString(Prefs.CAST_DEVICE_NAME, "Marco Movie 电视端");
        if (deviceName == null || deviceName.trim().isEmpty()) {
            deviceName = "Marco Movie 电视端";
        }

        LinearLayout actions = a.row();
        Button toggleBtn =
                a.button(
                        enabled ? "本机接收：已开启" : "本机接收：已关闭",
                        "primary",
                        () -> {
                            boolean next = !a.prefs.getBoolean(Prefs.CAST_ENABLED, true);
                            a.prefs.edit().putBoolean(Prefs.CAST_ENABLED, next).apply();
                            a.syncCastService();
                            a.toast(next ? "已开启本机投屏接收" : "已关闭本机投屏接收");
                            show();
                        });
        a.addButton(actions, toggleBtn);

        final String currentName = deviceName;
        Button renameBtn =
                a.navButton("设备名称：" + currentName, "cast-rename", () -> promptRename(currentName));
        a.addButton(actions, renameBtn);

        Button refreshBtn =
                a.navButton(
                        "重新广播",
                        "cast-refresh",
                        () -> {
                            a.restartCastService();
                            a.toast("已重新发送局域网 DLNA 设备发现广播");
                            bindReceiverPanel();
                        });
        a.addButton(actions, refreshBtn);

        Button manualBtn = a.navButton("播放流地址", "cast-manual-url", this::promptDirectStream);
        a.addButton(actions, manualBtn);
        a.body.addView(actions);
        a.gap(a.body, 16);

        LinearLayout columns = a.row();
        columns.setGravity(Gravity.TOP);

        // Left Card: TV Cast Receiver Info & Usage Guide
        LinearLayout infoCard = a.vertical();
        infoCard.setPadding(a.dp(24), a.dp(22), a.dp(24), a.dp(22));
        GradientDrawable infoBg = a.bg(0xc8171c26, 18);
        infoBg.setStroke(Math.max(1, a.dp(1)), 0x26ffffff);
        infoCard.setBackground(infoBg);

        TextView infoTitle = a.text("手机 / 平板投屏到本机电视", 20, MainActivity.WHITE);
        infoTitle.setTypeface(null, Typeface.BOLD);
        infoCard.addView(infoTitle);
        a.gap(infoCard, 10);

        TextView nameLabel = a.text("设备名称：" + deviceName, 16.5f, 0xff7cb8ff);
        nameLabel.setTypeface(null, Typeface.BOLD);
        infoCard.addView(nameLabel);
        a.gap(infoCard, 8);

        receiverBadgeView = a.text("", 13.5f, MainActivity.MUTED);
        receiverBadgeView.setLineSpacing(a.dp(3), 1f);
        infoCard.addView(receiverBadgeView);

        receiverIpView = a.text("", 12.5f, 0xff9fb0cc);
        receiverIpView.setPadding(0, a.dp(6), 0, 0);
        infoCard.addView(receiverIpView);

        a.gap(infoCard, 14);
        liveStatusView = a.text("", 13, 0xffd6e0f2);
        liveStatusView.setTag("cast-live-status");
        infoCard.addView(liveStatusView);

        a.gap(infoCard, 16);
        TextView guideTitle = a.text("投屏方式", 14.5f, MainActivity.WHITE);
        guideTitle.setTypeface(null, Typeface.BOLD);
        infoCard.addView(guideTitle);
        a.gap(infoCard, 6);
        TextView guide =
                a.text(
                        "1. 确保手机与本机电视连接在同一 Wi-Fi / 路由器局域网。\n"
                                + "2. 在爱奇艺、优酷、腾讯视频、哔哩哔哩或手机端 Marco Movie 播放页点击「投屏」，直接选择「"
                                + deviceName
                                + "」。\n"
                                + "3. 也可使用手机浏览器扫描右侧二维码，直接推送视频链接并远程控制播放进度与音量。",
                        13,
                        0xffbcc7dc);
        guide.setLineSpacing(a.dp(5), 1f);
        infoCard.addView(guide);

        LinearLayout.LayoutParams leftLp = new LinearLayout.LayoutParams(0, -2, 1.25f);
        leftLp.rightMargin = a.dp(20);
        columns.addView(infoCard, leftLp);

        // Right Card: Token-Scoped QR Web Direct-Cast Fallback
        LinearLayout qrCard = a.vertical();
        qrCard.setGravity(Gravity.CENTER_HORIZONTAL);
        qrCard.setPadding(a.dp(22), a.dp(22), a.dp(22), a.dp(22));
        GradientDrawable qrBg = a.bg(0xc8171c26, 18);
        qrBg.setStroke(Math.max(1, a.dp(1)), 0x26ffffff);
        qrCard.setBackground(qrBg);

        TextView qrTitle = a.text("扫码网页直投 / 手机遥控", 17.5f, MainActivity.WHITE);
        qrTitle.setTypeface(null, Typeface.BOLD);
        qrCard.addView(qrTitle);
        a.gap(qrCard, 12);

        qrHostView = a.vertical();
        qrHostView.setGravity(Gravity.CENTER_HORIZONTAL);
        qrCard.addView(qrHostView, new LinearLayout.LayoutParams(-1, -2));

        LinearLayout.LayoutParams rightLp = new LinearLayout.LayoutParams(0, -2, 0.75f);
        columns.addView(qrCard, rightLp);
        a.body.addView(columns, new LinearLayout.LayoutParams(-1, -2));

        bindReceiverPanel();
    }

    void onServiceReady() {
        if (a.isFinishing() || screenTicket != a.generation || a.activeCastScreen != this) return;
        bindReceiverPanel();
    }

    private void bindReceiverPanel() {
        if (receiverBadgeView == null || qrHostView == null) return;
        boolean enabled = a.prefs.getBoolean(Prefs.CAST_ENABLED, true);
        CastService svc = a.castService;
        updateReceiverBadge(enabled, svc);

        if (svc != null && !svc.lanIp.isEmpty()) {
            receiverIpView.setText("局域网地址：" + svc.lanIp + ":" + svc.httpPort());
            receiverIpView.setVisibility(View.VISIBLE);
        } else {
            receiverIpView.setVisibility(View.GONE);
        }

        if (liveStatusView != null) {
            liveStatusView.setText(
                    svc != null
                            ? "当前状态：" + svc.lastClientInfo
                            : (enabled ? "当前状态：等待局域网就绪…" : "当前状态：已关闭"));
        }

        qrHostView.removeAllViews();
        String webUrl = svc != null && enabled ? svc.webCastUrl() : "";
        if (!webUrl.isEmpty()) {
            try {
                int px =
                        Math.min(
                                a.dp(156),
                                Math.max(a.dp(120), Math.round(a.windowHeight() * 0.28f)));
                BitMatrix matrix = new QRCodeWriter().encode(webUrl, BarcodeFormat.QR_CODE, px, px);
                int[] pixels = new int[px * px];
                for (int y = 0; y < px; y++) {
                    for (int x = 0; x < px; x++) {
                        pixels[y * px + x] = matrix.get(x, y) ? Color.BLACK : Color.WHITE;
                    }
                }
                ImageView qr = new ImageView(a);
                qr.setTag("cast-qr");
                qr.setContentDescription("扫码直投二维码");
                qr.setImageBitmap(Bitmap.createBitmap(pixels, px, px, Bitmap.Config.ARGB_8888));
                qr.setPadding(a.dp(7), a.dp(7), a.dp(7), a.dp(7));
                qr.setBackground(a.bg(Color.WHITE, 12));
                qrHostView.addView(qr, new LinearLayout.LayoutParams(px + a.dp(14), px + a.dp(14)));
                a.gap(qrHostView, 8);
                TextView urlLabel = a.text(webUrl, 11.5f, 0xff7cb8ff);
                urlLabel.setTag("cast-web-url");
                urlLabel.setGravity(Gravity.CENTER);
                qrHostView.addView(urlLabel);
            } catch (Exception ignored) {
                qrHostView.addView(a.text("二维码生成失败，请点击重新广播", 12.5f, MainActivity.MUTED));
            }
        } else {
            TextView offHint =
                    a.text(
                            enabled ? "连接局域网后自动显示扫码直投入口" : "开启本机接收后可用手机选择本机投屏",
                            12.5f,
                            MainActivity.MUTED);
            offHint.setGravity(Gravity.CENTER);
            offHint.setPadding(a.dp(8), a.dp(24), a.dp(8), a.dp(24));
            qrHostView.addView(offHint);
        }
    }

    private void updateReceiverBadge(boolean enabled, CastService svc) {
        if (receiverBadgeView == null) return;
        if (!enabled) {
            receiverBadgeView.setText("● 本机投屏接收已关闭");
            receiverBadgeView.setTextColor(MainActivity.MUTED);
        } else if (svc != null && !svc.closed) {
            if (svc.ssdpActive) {
                receiverBadgeView.setText(
                        "● DLNA / Bonjour 接收在线 · 手机端视频软件与 Marco Movie iOS 均可直接发现");
            } else if (svc.bonjourActive) {
                receiverBadgeView.setText(
                        "● Bonjour / 局域网直连在线（系统占用 1900 端口，Marco Movie iOS 可自动发现）");
            } else {
                receiverBadgeView.setText("● 局域网直连在线（系统占用 1900 端口，Marco Movie iOS 可自动发现或输入下方 IP）");
            }
            receiverBadgeView.setTextColor(0xff66d4cf);
        } else {
            receiverBadgeView.setText("● 正在启动局域网投屏接收服务…");
            receiverBadgeView.setTextColor(0xffffb340);
        }
    }

    void refreshLiveStatus() {
        boolean enabled = a.prefs.getBoolean(Prefs.CAST_ENABLED, true);
        updateReceiverBadge(enabled, a.castService);
        if (liveStatusView != null && a.castService != null) {
            liveStatusView.setText("当前状态：" + a.castService.lastClientInfo);
        }
    }

    private void promptRename(String currentName) {
        LinearLayout box = a.vertical();
        box.setPadding(a.dp(8), a.dp(6), a.dp(8), a.dp(4));
        final EditText edit = new EditText(a);
        edit.setSingleLine(true);
        edit.setText(currentName);
        edit.setSelection(edit.getText().length());
        edit.setHint("例如：客厅电视 · Marco Movie");
        edit.setTextColor(MainActivity.WHITE);
        edit.setHintTextColor(MainActivity.MUTED);
        edit.setBackground(a.bg(0xff262832, 10));
        edit.setPadding(a.dp(14), a.dp(10), a.dp(14), a.dp(10));
        box.addView(TvQrInputHelper.wrap(a, edit, "投屏设备名称"), new LinearLayout.LayoutParams(-1, -2));
        new AppDialog.Builder(a)
                .setTitle("修改投屏设备名称")
                .setView(box)
                .setPositiveButton(
                        "保存",
                        (d, w) -> {
                            String next =
                                    SearchInputServer.sanitizeKeyword(
                                            edit.getText() == null
                                                    ? ""
                                                    : edit.getText().toString());
                            if (next.isEmpty()) next = "Marco Movie 电视端";
                            a.prefs.edit().putString(Prefs.CAST_DEVICE_NAME, next).apply();
                            if (a.castService != null) a.castService.updateFriendlyName(next);
                            a.toast("投屏名称已更新为：" + next);
                            show();
                        })
                .setNegativeButton("取消", null)
                .show();
    }

    private void promptDirectStream() {
        LinearLayout box = a.vertical();
        box.setPadding(a.dp(8), a.dp(6), a.dp(8), a.dp(4));
        final EditText edit = new EditText(a);
        edit.setSingleLine(true);
        edit.setHint("https://media.example/video.m3u8");
        edit.setTextColor(MainActivity.WHITE);
        edit.setHintTextColor(MainActivity.MUTED);
        edit.setBackground(a.bg(0xff262832, 10));
        edit.setPadding(a.dp(14), a.dp(10), a.dp(14), a.dp(10));
        box.addView(TvQrInputHelper.wrap(a, edit, "网络流地址"), new LinearLayout.LayoutParams(-1, -2));
        new AppDialog.Builder(a)
                .setTitle("播放网络流地址")
                .setView(box)
                .setPositiveButton(
                        "立即播放",
                        (d, w) -> {
                            String valid =
                                    CastService.validateCastMediaUrl(
                                            edit.getText() == null
                                                    ? ""
                                                    : edit.getText().toString());
                            if (valid.isEmpty()) {
                                a.toast("请输入有效的 HTTP / HTTPS 视频流地址");
                                return;
                            }
                            if (a.castService != null) {
                                a.castService.bridge.openMedia(
                                        valid, "网络直链播放", Collections.emptyMap(), 0);
                            } else {
                                Cms.Site castSite = new Cms.Site();
                                castSite.key = "cast";
                                castSite.originalKey = "cast";
                                castSite.name = "无线投屏";
                                castSite.type = 1;
                                Cms.Video v = new Cms.Video();
                                v.id = "cast:" + valid;
                                v.title = "网络直链播放";
                                Cms.Episode ep = new Cms.Episode();
                                ep.name = v.title;
                                ep.url = valid;
                                a.activeLine = null;
                                a.activeEpisode = null;
                                a.playingBookmark = null;
                                a.resumeAt = 0;
                                a.openPlayer(castSite, v, ep);
                            }
                        })
                .setNegativeButton("取消", null)
                .show();
    }
}
