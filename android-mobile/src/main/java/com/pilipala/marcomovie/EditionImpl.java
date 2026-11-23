package com.pilipala.marcomovie;

import android.graphics.Bitmap;
import android.graphics.Color;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.URL;
import java.net.URLEncoder;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicReference;

/** Mobile edition UI bridge compiled exclusively into {@code -android-mobile.apk}. */
final class EditionImpl {
    static final boolean IS_TV = false;

    private EditionImpl() {}

    static void showHome(MainActivity a) {
        MobileRootShell.show(a);
    }

    static void showContentHome(MainActivity a, Cms.Site site) {
        MobileRootShell.show(a);
    }

    static boolean resumeScreen(MainActivity a, MainActivity.Screen screen) {
        return screen != null && screen.mobileHome != null && screen.mobileHome.resume();
    }

    static boolean handleBackOnHome(MainActivity a) {
        if (a.mobileShell != null && a.mobileShell.handleBack()) {
            return true;
        }
        return false;
    }

    static void showImportDialog(MainActivity a) {
        UiWidgets.showMobileImportDialog(a);
    }

    static void showLanReceiver(MainActivity a) {
        showMobileLanTransferSheet(a);
    }

    static void showDetail(MainActivity a, Cms.Site site, Cms.Video listing, Cms.Video ready) {
        MobileDetailScreen.show(a, site, listing, ready);
    }

    static void openLiveSources(MainActivity a) {
        MobileRootShell.openTab(a, MobileRootShell.TAB_LIVE);
    }

    static void openSearch(MainActivity a, String initial) {
        MobileRootShell.openSearch(a, initial);
    }

    static void openSettings(MainActivity a) {
        MobileRootShell.openTab(a, MobileRootShell.TAB_SETTINGS);
    }

    static void onStartupReady(MainActivity a, boolean layoutIntro) {}

    static void closeSearchIfOpen(MainActivity a) {
        if (a.inlinePlayer != null) {
            a.inlinePlayer.detach();
            a.inlinePlayer = null;
        }
    }

    static void resetHomeDock(MainActivity a, boolean createDock) {}

    static boolean isAnchorInHomeDock(MainActivity a, View anchor) {
        return false;
    }

    static boolean dispatchIntroKey(MainActivity a, KeyEvent event) {
        return false;
    }

    static boolean dispatchHomeKey(MainActivity a, KeyEvent event) {
        return false;
    }

    static void onActivityStop(MainActivity a) {
        if (a.inlinePlayer != null && !a.mobilePrefs().getBoolean(Prefs.BACKGROUND_PLAY, false)) {
            a.inlinePlayer.pause();
        }
    }

    static void onActivityDestroy(MainActivity a) {
        if (a.inlinePlayer != null) {
            a.inlinePlayer.detach();
            a.inlinePlayer = null;
        }
        if (a.mobilePlayerOverlay != null) {
            a.mobilePlayerOverlay.detach();
            a.mobilePlayerOverlay = null;
        }
    }

    static void onPrivacySwitch(MainActivity a) {
        MobileRootShell.resetStaticState();
    }

    static void onSourceSaved(MainActivity a) {
        MobileRootShell.show(a);
    }

    static void minimizePlayback(MainActivity a) {}

    static void expandPlayback(MainActivity a) {}

    static void clearMiniDetails(MainActivity a) {
        if (a.mobilePlayerOverlay != null) {
            a.mobilePlayerOverlay.detach();
            a.mobilePlayerOverlay = null;
        }
    }

    static boolean interceptResolvedPlayback(
            MainActivity a, Cms.Site s, Cms.Video v, Cms.Episode e) {
        if (a.inlinePlayer != null && a.inlinePlayer.acceptsResolved(s, v)) {
            a.inlinePlayer.playResolved(s, v, e);
            return true;
        }
        return false;
    }

    static void attachPlayerOverlay(
            MainActivity a,
            VideoOutput surface,
            Cms.Site site,
            Cms.Video video,
            Cms.Episode episode) {
        TouchPlayerGesture.attach(a, surface);
        if (a.mobilePlayerOverlay != null) {
            a.mobilePlayerOverlay.detach();
        }
        a.mobilePlayerOverlay = new MobilePlayerOverlay(a, site, video, episode);
    }

    /**
     * Mobile-as-controller/sender LAN utility: push current subscription URL to a Marco Movie TV on
     * the same LAN or open a temporary QR receiver for peer-to-peer LAN sync.
     */
    static void showMobileLanTransferSheet(MainActivity a) {
        LinearLayout panel = a.vertical();
        panel.setPadding(a.dp(4), a.dp(6), a.dp(4), a.dp(4));
        panel.addView(
                a.text(
                        "输入同一局域网内 Marco Movie 电视端显示的配对地址，即可将手机当前片源地址一键推送至电视：",
                        13,
                        MainActivity.MUTED));
        a.gap(panel, 10);

        final EditText tvUrlInput = new EditText(a);
        tvUrlInput.setHint("http://tv.example.test:端口/...");
        tvUrlInput.setHintTextColor(0xff6b7280);
        tvUrlInput.setTextColor(MainActivity.WHITE);
        tvUrlInput.setTextSize(14);
        tvUrlInput.setSingleLine(true);
        tvUrlInput.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
        tvUrlInput.setBackground(a.bg(0xff1e2623, 12));
        panel.addView(tvUrlInput, new LinearLayout.LayoutParams(-1, -2));
        a.gap(panel, 10);

        final EditText payloadInput = new EditText(a);
        payloadInput.setHint("要推送给电视的配置网址 (https://…)");
        payloadInput.setHintTextColor(0xff6b7280);
        payloadInput.setTextColor(MainActivity.WHITE);
        payloadInput.setTextSize(13.5f);
        payloadInput.setSingleLine(true);
        payloadInput.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
        payloadInput.setBackground(a.bg(0xff1e2623, 12));
        if (a.configOrigin != null && !a.configOrigin.isEmpty()) {
            payloadInput.setText(a.configOrigin);
        }
        panel.addView(payloadInput, new LinearLayout.LayoutParams(-1, -2));

        new AppDialog.Builder(a)
                .setTitle("发送到电视 / 局域网互联")
                .setView(panel)
                .setNegativeButton("取消", null)
                .setNeutralButton("本机同步码", (d, w) -> showLocalSyncQr(a))
                .setPositiveButton(
                        "推送至电视",
                        (d, w) -> {
                            final String target = tvUrlInput.getText().toString().trim();
                            final String originUrl = payloadInput.getText().toString().trim();
                            if (!Cms.isHttp(target) || !Cms.isHttp(originUrl)) {
                                a.toast("请填写有效的局域网接收地址与 HTTP/HTTPS 配置地址");
                                return;
                            }
                            a.worker.execute(
                                    () -> {
                                        try {
                                            HttpURLConnection conn =
                                                    (HttpURLConnection)
                                                            new URL(Cms.normalizeHttp(target))
                                                                    .openConnection();
                                            conn.setRequestMethod("POST");
                                            conn.setDoOutput(true);
                                            conn.setConnectTimeout(8000);
                                            conn.setReadTimeout(12000);
                                            conn.setRequestProperty(
                                                    "Content-Type",
                                                    "application/x-www-form-urlencoded; charset=UTF-8");
                                            byte[] body =
                                                    ("url=" + URLEncoder.encode(originUrl, "UTF-8"))
                                                            .getBytes("UTF-8");
                                            try (OutputStream out = conn.getOutputStream()) {
                                                out.write(body);
                                            }
                                            int code = conn.getResponseCode();
                                            conn.disconnect();
                                            a.ui.post(
                                                    () ->
                                                            a.toast(
                                                                    code >= 200 && code < 300
                                                                            ? "已成功推送至电视端"
                                                                            : "电视端返回状态码：" + code));
                                        } catch (Exception ex) {
                                            a.ui.post(() -> a.toast("推送失败：" + a.message(ex)));
                                        }
                                    });
                        })
                .show();
    }

    private static void showLocalSyncQr(MainActivity a) {
        try {
            String ip = lanIp();
            final ConfigTransferServer server =
                    new ConfigTransferServer(
                            address -> {
                                Cms.Config cfg =
                                        Cms.parseConfig(
                                                SourceController.fetchImport(a, address),
                                                SourceController.importOrigin(address));
                                CountDownLatch latch = new CountDownLatch(1);
                                AtomicReference<Exception> err = new AtomicReference<>();
                                a.ui.post(
                                        () -> {
                                            try {
                                                a.saveConfig(
                                                        cfg,
                                                        SourceController.importOrigin(address));
                                                a.toast("已接收局域网配置");
                                            } catch (Exception e) {
                                                err.set(e);
                                            } finally {
                                                latch.countDown();
                                            }
                                        });
                                latch.await();
                                if (err.get() != null) throw err.get();
                            },
                            CloudSyncDialog.lanSyncHandler(a));
            String url = server.address(ip);
            int size = a.dp(180);
            BitMatrix m = new QRCodeWriter().encode(url, BarcodeFormat.QR_CODE, size, size);
            int[] px = new int[size * size];
            for (int y = 0; y < size; y++) {
                for (int x = 0; x < size; x++) {
                    px[y * size + x] = m.get(x, y) ? Color.BLACK : Color.WHITE;
                }
            }
            Bitmap bmp = Bitmap.createBitmap(px, size, size, Bitmap.Config.ARGB_8888);
            LinearLayout box = a.vertical();
            box.setGravity(Gravity.CENTER_HORIZONTAL);
            ImageView qr = new ImageView(a);
            qr.setImageBitmap(bmp);
            qr.setPadding(a.dp(10), a.dp(10), a.dp(10), a.dp(10));
            qr.setBackground(a.bg(Color.WHITE, 14));
            box.addView(qr, new LinearLayout.LayoutParams(size + a.dp(20), size + a.dp(20)));
            a.gap(box, 10);
            TextView addr = a.text(url, 12.5f, MainActivity.MUTED);
            addr.setGravity(Gravity.CENTER);
            box.addView(addr);
            AppDialog dlg =
                    new AppDialog.Builder(a)
                            .setTitle("本机局域网同步接收码")
                            .setView(box)
                            .setNegativeButton("关闭", (d, w) -> server.close())
                            .create();
            dlg.setOnDismissListener(d -> server.close());
            dlg.show();
        } catch (Exception e) {
            a.toast("无法启动局域网接收：" + a.message(e));
        }
    }

    private static String lanIp() throws Exception {
        List<NetworkInterface> list = Collections.list(NetworkInterface.getNetworkInterfaces());
        for (NetworkInterface nif : list) {
            if (nif.isUp() && !nif.isLoopback()) {
                for (InetAddress ip : Collections.list(nif.getInetAddresses())) {
                    if (ip instanceof Inet4Address && ip.isSiteLocalAddress()) {
                        return ip.getHostAddress();
                    }
                }
            }
        }
        throw new java.io.IOException("未检测到局域网连接");
    }
}
